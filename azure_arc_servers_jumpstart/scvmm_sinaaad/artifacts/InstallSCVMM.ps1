param (
    [string]$adminUsername,
    [string]$adminPassword,
    [string]$addsDomainName
)

[System.Environment]::SetEnvironmentVariable('adminUsername', $adminUsername, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('adminPassword', $adminPassword, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('addsDomainName', $addsDomainName, [System.EnvironmentVariableTarget]::Machine)


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

    
 
    $tempFolderName = "Temp"
    $tempFolder = "C:\" + $tempFolderName +"\"
    $itemType = "Directory"
    
    $SCVMMUrl = "https://go.microsoft.com/fwlink/p/?LinkID=2195845&clcid=0x409&culture=en-us&country=US"
    $SCVMMFile = $tempFolder + "SCVMM_2022.exe"
    New-Item -Path "C:\" -Name $tempFolderName -ItemType $itemType -Force | Out-Null
    
    Invoke-WebRequest -Uri $SCVMMUrl -OutFile $SCVMMFile

    

