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