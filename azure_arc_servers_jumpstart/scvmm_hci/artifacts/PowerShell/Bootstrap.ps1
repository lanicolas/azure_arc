param (
    [string]$adminUsername,
    [string]$adminPassword,
    [string]$spnClientId,
    [string]$spnClientSecret,
    [string]$spnTenantId,
    [string]$subscriptionId,
    [string]$resourceGroup,
    [string]$azureLocation,
    [string]$stagingStorageAccountName,
    [string]$workspaceName,
    [string]$templateBaseUrl,

    [string]$deployResourceBridge,
    [string]$natDNS,
    [string]$rdpPort
)

[System.Environment]::SetEnvironmentVariable('adminUsername', $adminUsername,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnClientID', $spnClientId,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnClientSecret', $spnClientSecret,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnTenantId', $spnTenantId,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_CLIENT_ID', $spnClientId,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_CLIENT_SECRET', $spnClientSecret,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_TENANT_ID', $spnTenantId,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('subscriptionId', $subscriptionId,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('resourceGroup', $resourceGroup,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('azureLocation', $azureLocation,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('stagingStorageAccountName', $stagingStorageAccountName,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('workspaceName', $workspaceName,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('templateBaseUrl', $templateBaseUrl,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('deployResourceBridge', $deployResourceBridge,[System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('natDNS', $natDNS,[System.EnvironmentVariableTarget]::Machine)

#######################################################################
## Setup basic environment
#######################################################################
# Copy PowerShell Profile and Reload
Invoke-WebRequest ($templateBaseUrl + "artifacts/PowerShell/PSProfile.ps1") -OutFile $PsHome\Profile.ps1
.$PsHome\Profile.ps1

# Creating SCVMM path
$scvmmPath = "C:\SCVMM"
[System.Environment]::SetEnvironmentVariable('SCVMMDir', $scvmmPath,[System.EnvironmentVariableTarget]::Machine)
New-Item -Path $scvmmPath -ItemType directory -Force

# Downloading configuration file
$ConfigurationDataFile = "$scvmmPath\SCVMM-Config.psd1"
[System.Environment]::SetEnvironmentVariable('SCVMMConfigFile', $ConfigurationDataFile,[System.EnvironmentVariableTarget]::Machine)
Invoke-WebRequest ($templateBaseUrl + "artifacts/PowerShell/SCVMM-Config.psd1") -OutFile $ConfigurationDataFile

# Importing configuration data
$SCVMMConfig = Import-PowerShellDataFile -Path $ConfigurationDataFile

# Create paths
foreach ($path in $SCVMMConfig.Paths.GetEnumerator()) {
    Write-Output "Creating path $($path.Value)"
    New-Item -Path $path.Value -ItemType directory -Force | Out-Null
}

# Begin transcript
Start-Transcript -Path "$($SCVMMConfig.Paths["LogsDir"])\Bootstrap.log"

#################################################################################
## Setup host infrastructure and apps
#################################################################################
# Extending C:\ partition to the maximum size
Write-Host "Extending C:\ partition to the maximum size"
Resize-Partition -DriveLetter C -Size $(Get-PartitionSupportedSize -DriveLetter C).SizeMax

# Installing tools
Write-Header "Installing Chocolatey Apps"
try {
    choco config get cacheLocation
}
catch {
    Write-Output "Chocolatey not detected, trying to install now"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

foreach ($app in $SCVMMConfig.ChocolateyPackagesList)
{
    Write-Host "Installing $app"
    & choco install $app /y -Force | Write-Output
}

Write-Header "Install Azure CLI (64-bit not available via Chocolatey)"
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile .\AzureCLI.msi
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
Remove-Item .\AzureCLI.msi

Write-Host "Downloading Azure Stack scvmm configuration scripts"
Invoke-WebRequest "https://raw.githubusercontent.com/microsoft/azure_arc/main/img/jumpstart_wallpaper.png" -OutFile $scvmmPath\wallpaper.png
Invoke-WebRequest https://aka.ms/wacdownload -OutFile "$($SCVMMConfig.Paths["WACDir"])\WindowsAdminCenter.msi"
Invoke-WebRequest ($templateBaseUrl + "artifacts/PowerShell/SCVMMLogonScript.ps1") -OutFile $scvmmPath\SCVMMLogonScript.ps1
Invoke-WebRequest ($templateBaseUrl + "artifacts/PowerShell/New-SCVMM.ps1") -OutFile $scvmmPath\New-SCVMM.ps1
Invoke-WebRequest ($templateBaseUrl + "artifacts/PowerShell/Configure-VMLogicalNetwork.ps1") -OutFile $scvmmPath\Configure-VMLogicalNetwork.ps1

# Replace password and DNS placeholder
Write-Host "Updating config placeholders with injected values."
$adminPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($adminPassword))
(Get-Content -Path $scvmmPath\SCVMM-Config.psd1) -replace '%staging-password%',$adminPassword | Set-Content -Path $scvmmPath\SCVMM-Config.psd1
(Get-Content -Path $scvmmPath\SCVMM-Config.psd1) -replace '%staging-natDNS%',$natDNS | Set-Content -Path $scvmmPath\SCVMM-Config.psd1

# Disabling Windows Server Manager Scheduled Task
Write-Host "Disabling Windows Server Manager scheduled task."
Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask

# Disable Server Manager WAC prompt
Write-Host "Disabling Server Manager WAC prompt."
$RegistryPath = "HKLM:\SOFTWARE\Microsoft\ServerManager"
$Name = "DoNotPopWACConsoleAtSMLaunch"
$Value = "1"
if (-not (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force

# Disable Network Profile prompt
Write-Host "Disabling network profile prompt."
$RegistryPath = "HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff"
if (-not (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}

# Configuring CredSSP and WinRM
Write-Host "Enabling CredSSP."
Enable-WSManCredSSP -Role Server -Force | Out-Null
Enable-WSManCredSSP -Role Client -DelegateComputer $Env:COMPUTERNAME -Force | Out-Null

# Creating scheduled task for SCVMMLogonScript.ps1
Write-Host "Creating scheduled task for SCVMMLogonScript.ps1"
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $scvmmPath\SCVMMLogonScript.ps1
Register-ScheduledTask -TaskName "SCVMMLogonScript" -Trigger $Trigger -User $adminUsername -Action $Action -RunLevel "Highest" -Force

# Disable Edge 'First Run' Setup
Write-Host "Configuring Microsoft Edge."
$edgePolicyRegistryPath  = 'HKLM:SOFTWARE\Policies\Microsoft\Edge'
$firstRunRegistryName  = 'HideFirstRunExperience'
$firstRunRegistryValue = '0x00000001'
$savePasswordRegistryName = 'PasswordManagerEnabled'
$savePasswordRegistryValue = '0x00000000'

if (-NOT (Test-Path -Path $edgePolicyRegistryPath)) {
    New-Item -Path $edgePolicyRegistryPath -Force | Out-Null
}

New-ItemProperty -Path $edgePolicyRegistryPath -Name $firstRunRegistryName -Value $firstRunRegistryValue -PropertyType DWORD -Force
New-ItemProperty -Path $edgePolicyRegistryPath -Name $savePasswordRegistryName -Value $savePasswordRegistryValue -PropertyType DWORD -Force

# Change RDP Port
Write-Host "Updating RDP Port - RDP port number from configuration is $rdpPort"
if (($rdpPort -ne $null) -and ($rdpPort -ne "") -and ($rdpPort -ne "3389"))
{
    Write-Host "Configuring RDP port number to $rdpPort"
    $TSPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $RDPTCPpath = $TSPath + '\Winstations\RDP-Tcp'
    Set-ItemProperty -Path $TSPath -name 'fDenyTSConnections' -Value 0

    # RDP port
    $portNumber = (Get-ItemProperty -Path $RDPTCPpath -Name 'PortNumber').PortNumber
    Write-Host "Current RDP PortNumber: $portNumber"
    if (!($portNumber -eq $rdpPort))
    {
      Write-Host Setting RDP PortNumber to $rdpPort
      Set-ItemProperty -Path $RDPTCPpath -name 'PortNumber' -Value $rdpPort
      Restart-Service TermService -force
    }

    #Setup firewall rules
    if ($rdpPort -eq 3389)
    {
      netsh advfirewall firewall set rule group="remote desktop" new Enable=Yes
    } 
    else
    {
      $systemroot = get-content env:systemroot
      netsh advfirewall firewall add rule name="Remote Desktop - Custom Port" dir=in program=$systemroot\system32\svchost.exe service=termservice action=allow protocol=TCP localport=$RDPPort enable=yes
    }

    Write-Host "RDP port configuration complete."
}

# Install Hyper-V and reboot
Write-Header "Installing Hyper-V."
Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools -Restart

# Clean up Bootstrap.log
Write-Header "Clean up Bootstrap.log."
Stop-Transcript
$logSuppress = Get-Content "$($SCVMMConfig.Paths.LogsDir)\Bootstrap.log" | Where-Object { $_ -notmatch "Host Application: powershell.exe" } 
$logSuppress | Set-Content "$($SCVMMConfig.Paths.LogsDir)\Bootstrap.log" -Force
