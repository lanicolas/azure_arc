# Script runtime environment: Level-0 Azure virtual machine ("Client VM")
$ProgressPreference = "SilentlyContinue"
Set-PSDebug -Strict

#####################################################################
# Initialize the environment
#####################################################################

# Load config file
$SCVMMConfig = Import-PowerShellDataFile -Path $Env:SCVMMConfigFile

Start-Transcript -Path "$($SCVMMConfig.Paths.LogsDir)\SCVMMLogonScript.log"

#####################################################################
# Setup Azure CLI
#####################################################################
$cliDir = New-Item -Path "$Env:SCVMMDir\.cli\" -Name ".servers" -ItemType Directory

if(-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
    $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
    $folder.Attributes += [System.IO.FileAttributes]::Hidden
}

$Env:AZURE_CONFIG_DIR = $cliDir.FullName

# Login to Azure CLI with service principal provided by user
Write-Header "Az CLI Login"
az login --service-principal --username $Env:spnClientID --password=$Env:spnClientSecret --tenant $Env:spnTenantId

#####################################################################
# Register Azure providers
#####################################################################

# Register Azure providers
Write-Header "Registering Providers"
az provider register --namespace Microsoft.HybridCompute --wait
az provider register --namespace Microsoft.GuestConfiguration --wait
az provider register --namespace Microsoft.ExtendedLocation --wait
az provider register --namespace Microsoft.OperationsManagement --wait
az provider register --namespace Microsoft.ResourceConnector --wait


#####################################################################
# Configure virtualization infrastructure
#####################################################################

# Configure storage pools and data disks
Write-Header "Configuring storage"
New-StoragePool -FriendlyName scvmmpool -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $true)
$disks = Get-StoragePool -FriendlyName scvmmpool -IsPrimordial $False | Get-PhysicalDisk
$diskNum = $disks.Count
New-VirtualDisk -StoragePoolFriendlyName scvmmpool -FriendlyName scvmmDisk -ResiliencySettingName Simple -NumberOfColumns $diskNum -UseMaximumSize
$vDisk = Get-VirtualDisk -FriendlyName scvmmDisk
if ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'raw') {
    $vDisk | Get-Disk | Initialize-Disk -Passthru | New-Partition -DriveLetter $SCVMMConfig.HostVMDriveLetter -UseMaximumSize | Format-Volume -NewFileSystemLabel SCVMMData -AllocationUnitSize 64KB -FileSystem NTFS
}
elseif ($vDisk | Get-Disk | Where-Object PartitionStyle -eq 'GPT') {
    $vDisk | Get-Disk | New-Partition -DriveLetter $SCVMMConfig.HostVMDriveLetter -UseMaximumSize | Format-Volume -NewFileSystemLabel SCVMMData -AllocationUnitSize 64KB -FileSystem NTFS
}

Stop-Transcript

# Build Environment
& "$Env:SCVMMDir\New-SCVMM.ps1"

Start-Transcript -Append -Path $Env:SCVMMLogsDir\SCVMMLogonScript.log

# Changing to Jumpstart wallpaper
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

Write-Header "Changing Wallpaper"
$imgPath="$Env:SCVMMDir\wallpaper.png"
Add-Type $code 
[Win32.Wallpaper]::SetWallpaper($imgPath)

# Removing the LogonScript Scheduled Task so it won't run on next reboot
Write-Header "Removing Logon Task"
Unregister-ScheduledTask -TaskName "SCVMMLogonScript" -Confirm:$false

# Executing the deployment logs bundle PowerShell script in a new window
Write-Header "Uploading Log Bundle"
Invoke-Expression 'cmd /c start Powershell -Command { 
    $RandomString = -join ((48..57) + (97..122) | Get-Random -Count 6 | % {[char]$_})
    Write-Host "Sleeping for 5 seconds before creating deployment logs bundle..."
    Start-Sleep -Seconds 5
    Write-Host "`n"
    Write-Host "Creating deployment logs bundle"
    7z a $Env:SCVMMLogsDir\LogsBundle-"$RandomString".zip $Env:SCVMMLogsDir\*.log
}'

Stop-Transcript