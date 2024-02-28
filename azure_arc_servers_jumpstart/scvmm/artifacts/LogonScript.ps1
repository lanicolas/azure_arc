$Env:SCVMMDir = "C:\SCVMM"
$Env:SCVMMLogsDir = "$Env:SCVMMDir\Logs"
$Env:SCVMMVMDir = "$Env:SCVMMDir\Virtual Machines"
$Env:SCVMMIconDir = "$Env:SCVMMDir\Icons"
$agentScript = "$Env:SCVMMDir\agentScript"

# Set variables to execute remote powershell scripts on guest VMs
$nestedVMSCVMMDir = $Env:SCVMMDir
$spnClientId = $env:spnClientId
$spnClientSecret = $env:spnClientSecret
$spnTenantId = $env:spnTenantId
$subscriptionId = $env:subscriptionId
$azureLocation = $env:azureLocation
$resourceGroup = $env:resourceGroup

# Moved VHD storage account details here to keep only in place to prevent duplicates.
$vhdSourceFolder = "https://jsvhds.blob.core.windows.net/arcbox"
$sas = "*?si=ArcBox-RL&spr=https&sv=2022-11-02&sr=c&sig=vg8VRjM00Ya%2FGa5izAq3b0axMpR4ylsLsQ8ap3BhrnA%3D"

azcopy cp $vhdSourceFolder/$sas --include-pattern "ArcBox-Win2K22.vhdx" $Env:SCVMMVMDir --check-length=false --cap-mbps 1200 --log-level=ERROR

################################################
# Setup Hyper-V server before deploying VMs for each flavor
################################################

    # Install and configure DHCP service (used by Hyper-V nested VMs)
    Write-Host "Configuring DHCP Service"
    $dnsClient = Get-DnsClient | Where-Object { $_.InterfaceAlias -eq "Ethernet" }
    $dhcpScope = Get-DhcpServerv4Scope
    if ($dhcpScope.Name -ne "SCVMM") {
        Add-DhcpServerv4Scope -Name "SCVMM" `
            -StartRange 10.10.1.100 `
            -EndRange 10.10.1.200 `
            -SubnetMask 255.255.255.0 `
            -LeaseDuration 1.00:00:00 `
            -State Active
    }

    $dhcpOptions = Get-DhcpServerv4OptionValue
    if ($dhcpOptions.Count -lt 3) {
        Set-DhcpServerv4OptionValue -ComputerName localhost `
            -DnsDomain $dnsClient.ConnectionSpecificSuffix `
            -DnsServer 168.63.129.16, 10.16.2.100 `
            -Router 10.10.1.1 `
            -Force
    }

    # Create the NAT network
    Write-Host "Creating Internal NAT"
    $natName = "InternalNat"
    $netNat = Get-NetNat
    if ($netNat.Name -ne $natName) {
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 10.10.1.0/24
    }

    # Create an internal switch with NAT
    Write-Host "Creating Internal vSwitch"
    $switchName = 'InternalNATSwitch'
    
    # Verify if internal switch is already created, if not create a new switch
    $inernalSwitch = Get-VMSwitch
    if ($inernalSwitch.Name -ne $switchName) {
        New-VMSwitch -Name $switchName -SwitchType Internal
        $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*" + $switchName + "*" }

        # Create an internal network (gateway first)
        Write-Host "Creating Gateway"
        New-NetIPAddress -IPAddress 10.10.1.1 -PrefixLength 24 -InterfaceIndex $adapter.ifIndex

        # Enable Enhanced Session Mode on Host
        Write-Host "Enabling Enhanced Session Mode"
        Set-VMHost -EnableEnhancedSessionMode $true
    }

    Write-Host "Creating VM Credentials"
    # Hard-coded username and password for the nested VMs
    $nestedWindowsUsername = "Administrator"
    $nestedWindowsPassword = "ArcDemo123!!"

    # Create Windows credential object
    $secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
    $winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

    # Creating Hyper-V Manager desktop shortcut
    Write-Host "Creating Hyper-V Shortcut"
    Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\All Users\Desktop" -Force

    # Configure the SCVMM Hyper-V host to allow the nested VMs onboard as Azure Arc-enabled servers
    Write-Header "Blocking IMDS"
    Write-Output "Configure the SCVMM VM to allow the nested VMs onboard as Azure Arc-enabled servers"
    Set-Service WindowsAzureGuestAgent -StartupType Disabled -Verbose
    Stop-Service WindowsAzureGuestAgent -Force -Verbose

    if (!(Get-NetFirewallRule -Name BlockAzureIMDS -ErrorAction SilentlyContinue).Enabled) {
        New-NetFirewallRule -Name BlockAzureIMDS -DisplayName "Block access to Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254
    }

    $cliDir = New-Item -Path "$Env:SCVMMDir\.cli\" -Name ".servers" -ItemType Directory -Force
    if (-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
        $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
        $folder.Attributes += [System.IO.FileAttributes]::Hidden
    }

    $Env:AZURE_CONFIG_DIR = $cliDir.FullName

    # Install Azure CLI extensions
    Write-Header "Az CLI extensions"
    az extension add --name ssh --yes --only-show-errors
    az extension add --name log-analytics-solution --yes --only-show-errors
    az extension add --name connectedmachine --yes --only-show-errors

    # Required for CLI commands
    Write-Header "Az CLI Login"
    az login --service-principal --username $spnClientId --password=$spnClientSecret --tenant $spnTenantId
    az account set -s $Env:subscriptionId

    # Register Azure providers
    Write-Header "Registering Providers"
    az provider register --namespace Microsoft.HybridCompute --wait --only-show-errors
    az provider register --namespace Microsoft.HybridConnectivity --wait --only-show-errors
    az provider register --namespace Microsoft.GuestConfiguration --wait --only-show-errors
    az provider register --namespace Microsoft.AzureArcData --wait --only-show-errors

    # Create the nested VMs if not already created
    Write-Header "Create Hyper-V VMs"

## Variables
 
$tempFolderName = "Temp"
$tempFolder = "C:\" + $tempFolderName +"\"
$itemType = "Directory"
 

$SCVMMUrl = "https://download.microsoft.com/download/b/4/e/b4e3a156-de31-4fe3-b149-8cdc0b2a2f84/SCVMM_2022.exe"
$SCVMMFile = $tempFolder + "SCVMM_2022.exe"
$SCVMMBin = "https://download.microsoft.com/download/b/4/e/b4e3a156-de31-4fe3-b149-8cdc0b2a2f84/"
 

# Downloading the required files 
New-Item -Path "C:\" -Name $tempFolderName -ItemType $itemType -Force | Out-Null

Invoke-WebRequest -Uri $SCVMMUrl -OutFile $SCVMMFile
for ($i=1; $i -lt 35; $i++) {
    $BinFile = $tempFolder + "SCVMM_2022-$i.bin"
    Invoke-WebRequest ($SCVMMBin + "SCVMM_2022-$i.bin") -OutFile $BinFile
}

Start-Process -Wait -FilePath .\SCVMM_2022.exe -Argument "/silent" -PassThru
$SCVMMName = "SCVMM"
$SCVMMvmvhdPath = "C:\System Center Virtual Machine Manager 2022\SCVMM.vhd"

Get-ChildItem "C:\System Center Virtual Machine Manager 2022" | Rename-Item -NewName "SCVMM.vhd"

Write-Host "Create SCVMM VM"
if ((Get-VM -Name $SCVMMName -ErrorAction SilentlyContinue).State -ne "Running") {
    Remove-VM -Name $SCVMMName -Force -ErrorAction SilentlyContinue
    New-VM -Name $SCVMMName -MemoryStartupBytes 8GB -BootDevice VHD -VHDPath $SCVMMvmvhdPath -Path $Env:SCVMMVMDir -Generation 1 -Switch $switchName
    Set-VMProcessor -VMName $SCVMMName -Count 2
    Set-VM -Name $SCVMMName -AutomaticStartAction Start -AutomaticStopAction ShutDown
}

# We always want the VMs to start with the host and shut down cleanly with the host
Write-Host "Set VM Auto Start/Stop"
Set-VM -Name $SCVMMName -AutomaticStartAction Start -AutomaticStopAction ShutDown

Write-Host "Enabling Guest Integration Service"
Get-VM -Name $SCVMMName | Get-VMIntegrationService | Where-Object { -not($_.Enabled) } | Enable-VMIntegrationService -Verbose

# Start all the VMs
Write-Host "Starting SCVMM VM"
Start-VM -Name $SCVMMName

# Restarting Windows VM Network Adapters
Write-Host "Restarting Network Adapters"
Start-Sleep -Seconds 20
Invoke-Command -VMName $SCVMMName -ScriptBlock { Get-NetAdapter | Restart-NetAdapter } -Credential $winCreds
Start-Sleep -Seconds 5

    # Copy installation script to nested Windows VMs
    Write-Output "Transferring installation script to nested Windows VMs..."
    Copy-VMFile $SCVMM -SourcePath "$agentScript\installSCVMM.ps1" -DestinationPath "$Env:SCVMMDir\installSCVMM.ps1" -CreateFullPath -FileSource Host -Force

    # Removing the LogonScript Scheduled Task so it won't run on next reboot
    Write-Header "Removing Logon Task"
    if ($null -ne (Get-ScheduledTask -TaskName "ArcServersLogonScript" -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName "ArcServersLogonScript" -Confirm:$false
    }



# Changing to Jumpstart  wallpaper
# Changing to Client VM wallpaper
$imgPath = "$Env:SCVMMDir\wallpaper.png"
$code = @' 
using System.Runtime.InteropServices; 
namespace Win32{ 
    
    public class Wallpaper{ 
        [DllImport("user32.dll", CharSet=CharSet.Auto)] 
        static extern int SystemParametersInfo (int uAction , int uParam , string lpvParam , int fuWinIni) ; 
        
        public static void SetWallpaper(string thePath){ 
            SystemParametersInfo(20,0,thePath,3); 
        }
    }
} 
'@

Stop-Transcript
