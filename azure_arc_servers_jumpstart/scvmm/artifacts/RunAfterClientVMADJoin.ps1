
##############################################
# This script will be executed after Client VM AD join setup scheduled task to run under domain account.
##############################################
Import-Module ActiveDirectory

$Env:SCVMMLogsDir = "C:\SCVMM\Logs"
$Env:SCVMMDir = "C:\SCVMM"
Start-Transcript -Path "$Env:SCVMMLogsDir\RunAfterClientVMADJoin.log"

# Get Activectory Information
$netbiosname = $Env:addsDomainName.Split('.')[0].ToUpper()

$adminuser = "$netbiosname\$Env:adminUsername"
$secpass = $Env:adminPassword | ConvertTo-SecureString -AsPlainText -Force
$adminCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $adminuser, $secpass
#$dcName = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName

$dcInfo = Get-ADDomainController -Credential $adminCredential

# Print domain information
Write-Host "===========Domain Controller Information============"
$dcInfo
Write-Host "===================================================="

# Create login session with domain credentials
$cimsession = New-CimSession -Credential $adminCredential

# Creating scheduled task for DataServicesLogonScript.ps1
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $adminuser
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "$Env:SCVMMDir\LogonScript.ps1"

# Register schedule task under local account
Register-ScheduledTask -TaskName "LogonScript" -Trigger $Trigger -Action $Action -RunLevel "Highest" -CimSession $cimsession -Force
Write-Host "Registered scheduled task 'LogonScript' to run at user logon."

#Disable local account
$account=(Get-LocalGroupMember -Group "Administrators" | where {$_.PrincipalSource -eq "Local"}).name.split('\')[1]
net user $account /active:no

# Delete schedule task
schtasks.exe /delete /f /tn RunAfterClientVMADJoin

Stop-Transcript