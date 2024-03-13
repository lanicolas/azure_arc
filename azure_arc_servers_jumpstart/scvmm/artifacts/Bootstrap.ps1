param (
    [string]$adminUsername,
    [string]$adminPassword,
    [string]$spnClientId,
    [string]$spnClientSecret,
    [string]$spnTenantId,
    [string]$spnAuthority,
    [string]$subscriptionId,
    [string]$resourceGroup,
    [string]$arcDcName,
    [string]$azureLocation,
    [string]$githubUser,
    [string]$templateBaseUrl,
    [string]$rdpPort
)

[System.Environment]::SetEnvironmentVariable('adminUsername', $adminUsername, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('adminPassword', $adminPassword, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnClientID', $spnClientId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnClientSecret', $spnClientSecret, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnTenantId', $spnTenantId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnAuthority', $spnAuthority, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_CLIENT_ID', $spnClientId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_CLIENT_SECRET', $spnClientSecret, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_TENANT_ID', $spnTenantId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_AUTHORITY', $spnAuthority, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('resourceGroup', $resourceGroup, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('arcDcName', $arcDcName, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('subscriptionId', $subscriptionId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('azureLocation', $azureLocation, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('githubUser', $githubUser, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('templateBaseUrl', $templateBaseUrl, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('automationTriggerAtLogon', $automationTriggerAtLogon, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('addsDomainName', "jumpstart.local", [System.EnvironmentVariableTarget]::Machine)

[System.Environment]::SetEnvironmentVariable('SCVMMDir', "C:\SCVMM", [System.EnvironmentVariableTarget]::Machine)

# Creating SCVMM path
Write-Output "Creating SCVMM path"
$Env:SCVMM = "C:\SCVMM"
$Env:SCVMMLogsDir = "$Env:SCVMMDir\Logs"
$Env:SCVMMVMDir = "$Env:SCVMMDir\Virtual Machines"
$Env:agentScript = "$Env:SCVMMDir\agentScript"
$Env:ToolsDir = "C:\Tools"
$Env:tempDir = "C:\Temp"

New-Item -Path $Env:SCVMMDir -ItemType directory -Force
New-Item -Path $Env:SCVMMLogsDir -ItemType directory -Force
New-Item -Path $Env:SCVMMVMDir -ItemType directory -Force
New-Item -Path $Env:ToolsDir -ItemType Directory -Force
New-Item -Path $Env:tempDir -ItemType directory -Force
New-Item -Path $Env:agentScript -ItemType directory -Force

Start-Transcript -Path $Env:SCVMMLogsDir\Bootstrap.log

$ErrorActionPreference = 'SilentlyContinue'

# Copy PowerShell Profile and Reload
Invoke-WebRequest ($templateBaseUrl + "artifacts/PSProfile.ps1") -OutFile $PsHome\Profile.ps1
.$PsHome\Profile.ps1

# Extending C:\ partition to the maximum size
Write-Host "Extending C:\ partition to the maximum size"
Resize-Partition -DriveLetter C -Size $(Get-PartitionSupportedSize -DriveLetter C).SizeMax

# Installing Posh-SSH PowerShell Module
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name Posh-SSH -Force

# Installing DHCP service
Write-Output "Installing DHCP service"
Install-WindowsFeature -Name "DHCP" -IncludeManagementTools

#Installing AD DS roles

Install-WindowsFeature -Name RSAT-AD-PowerShell
Install-WindowsFeature -Name RSAT-DNS-Server

# Installing tools
Write-Header "Installing Chocolatey Apps"
$chocolateyAppList = 'az.powershell,kubernetes-cli,vcredist140,microsoft-edge,azcopy10,vscode,git,7zip,ssms,dotnet-sdk,setdefaultbrowser,openssl.light'

try {
    choco config get cacheLocation
}
catch {
    Write-Output "Chocolatey not detected, trying to install now"
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
}

Write-Host "Chocolatey Apps Specified"

$appsToInstall = $chocolateyAppList -split "," | ForEach-Object { "$($_.Trim())" }

foreach ($app in $appsToInstall) {
    Write-Host "Installing $app"
    & choco install $app /y -Force | Write-Output

}

Write-Header "Installing Azure CLI (64-bit not available via Chocolatey)"

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindowsx64 -OutFile .\AzureCLI.msi
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
Remove-Item .\AzureCLI.msi

Write-Header "Fetching GitHub Artifacts"
Invoke-WebRequest ($Env:templateBaseUrl + "artifacts/LogonScript.ps1") -OutFile $Env:SCVMMDir\LogonScript.ps1
Invoke-WebRequest ($Env:templateBaseUrl + "artifacts/RunAfterClientVMADJoin.ps1") -OutFile $Env:SCVMMDir\RunAfterClientVMADJoin.ps1
Invoke-WebRequest ($Env:templateBaseUrl + "artifacts/InstallSCVMM.ps1") -OutFile $Env:SCVMMDir\SCVMM.ps1

# Disable Microsoft Edge sidebar
$RegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$Name         = 'HubsSidebarEnabled'
$Value        = '00000000'
# Create the key if it does not exist
If (-NOT (Test-Path $RegistryPath)) {
  New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force

# Disable Microsoft Edge first-run Welcome screen
$RegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$Name         = 'HideFirstRunExperience'
$Value        = '00000001'
# Create the key if it does not exist
If (-NOT (Test-Path $RegistryPath)) {
  New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force


# Change RDP Port
Write-Host "RDP port number from configuration is $rdpPort"
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

Write-Header "Configuring Logon Scripts"
    # Creating scheduled task for LogonScript.ps1
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $Env:SCVMMDir\LogonScript.ps1
    Register-ScheduledTask -TaskName "LogonScript" -Trigger $Trigger -User $adminUsername -Action $Action -RunLevel "Highest" -Force

    # Joining ClientVM to AD DS domain
    $netbiosname = $Env:addsDomainName.Split(".")[0]
    $computername = $env:COMPUTERNAME

    $domainCred = New-Object pscredential -ArgumentList ([pscustomobject]@{
            UserName = "${netbiosname}\${adminUsername}"
            Password = (ConvertTo-SecureString -String $adminPassword -AsPlainText -Force)[0]
        })

    $localCred = New-Object pscredential -ArgumentList ([pscustomobject]@{
            UserName = "${computername}\${adminUsername}"
            Password = (ConvertTo-SecureString -String $adminPassword -AsPlainText -Force)[0]
        })


    $Trigger = New-ScheduledTaskTrigger -AtStartup
    $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "$Env:SCVMMDir\RunAfterClientVMADJoin.ps1"
    Register-ScheduledTask -TaskName "RunAfterClientVMADJoin" -Trigger $Trigger -User SYSTEM -Action $Action -RunLevel "Highest" -Force
    Write-Host "Registered scheduled task 'RunAfterClientVMADJoin' to run after Client VM AD join."

    Write-Host "`n"
    Write-Host "Joining client VM to domain"
    Add-Computer -DomainName $Env:addsDomainName -LocalCredential $localCred -Credential $domainCred
    Write-Host "Joined Client VM to $addsDomainName domain."

    # Disabling Windows Server Manager Scheduled Task
    Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask

    # Install Hyper-V and reboot
    Write-Host "Installing Hyper-V and restart"
    Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
    Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools -Restart

    # Clean up Bootstrap.log
    Stop-Transcript
    $logSuppress = Get-Content $bootstrapLogFile | Where-Object { $_ -notmatch "Host Application: powershell.exe" }
    $logSuppress | Set-Content $bootstrapLogFile -Force

    # Restart computer
    Restart-Computer

