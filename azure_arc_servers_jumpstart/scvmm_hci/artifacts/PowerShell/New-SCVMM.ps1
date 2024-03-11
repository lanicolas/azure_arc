﻿# Set paths
$Env:SCVMMDir = "C:\SCVMM"
$Env:SCVMMLogsDir = "C:\SCVMM\Logs"

Start-Transcript -Path $Env:SCVMMLogsDir\New-SCVMM.log
$starttime = Get-Date

# Import Configuration data file
$SCVMMConfig = Import-PowerShellDataFile -Path $Env:SCVMMConfigFile

#region functions
function BITSRequest {
    param (
        [Parameter(Mandatory=$True)]
        [hashtable]$Params
    )
    $url = $Params['Uri']
    $filename = $Params['Filename']
    $download = Start-BitsTransfer -Source $url -Destination $filename -Asynchronous
    $ProgressPreference = "Continue"
    while ($download.JobState -ne "Transferred") {
        if ($download.JobState -eq "TransientError"){
            Get-BitsTransfer $download.name | Resume-BitsTransfer -Asynchronous
        }
        [int] $dlProgress = ($download.BytesTransferred / $download.BytesTotal) * 100;
        Write-Progress -Activity "Downloading File $filename..." -Status "$dlProgress% Complete:" -PercentComplete $dlProgress; 
    }
    Complete-BitsTransfer $download.JobId
    Write-Progress -Activity "Downloading File $filename..." -Status "Ready" -Completed
    $ProgressPreference = "SilentlyContinue"
}
    
function New-InternalSwitch {
    param (
        $SCVMMConfig
    )
    $pswitchname = $SCVMMConfig.InternalSwitch
    $querySwitch = Get-VMSwitch -Name $pswitchname -ErrorAction Ignore
    if (!$querySwitch) {
        New-VMSwitch -SwitchType Internal -MinimumBandwidthMode None -Name $pswitchname | Out-Null
    
        #Assign IP to Internal Switch
        $InternalAdapter = Get-Netadapter -Name "vEthernet ($pswitchname)"
        $IP = $SCVMMConfig.PhysicalHostInternalIP
        $Prefix = ($($SCVMMConfig.MgmtHostConfig.IP).Split("/"))[1]
        $Gateway = $SCVMMConfig.SDNLABRoute
        $DNS = $SCVMMConfig.SDNLABDNS
        
        $params = @{
            AddressFamily  = "IPv4"
            IPAddress      = $IP
            PrefixLength   = $Prefix
            DefaultGateway = $Gateway
        }
    
        $InternalAdapter | New-NetIPAddress @params | Out-Null
        $InternalAdapter | Set-DnsClientServerAddress -ServerAddresses $DNS | Out-Null
    }
    else { 
        Write-Host "Internal Switch $pswitchname already exists. Not creating a new internal switch." 
    } 
}

function Get-FormattedWACMAC {
    Param(
        $SCVMMConfig
    )
    return $SCVMMConfig.WACMAC -replace '..(?!$)', '$&-'
}

function GenerateAnswerFile {
    Param(
        [Parameter(Mandatory=$True)] $Hostname,
        [Parameter(Mandatory=$False)] $IsMgmtVM = $false,
        [Parameter(Mandatory=$False)] $IsRouterVM = $false,
        [Parameter(Mandatory=$False)] $IsDCVM = $false,
        [Parameter(Mandatory=$False)] $IsWACVM = $false,
        [Parameter(Mandatory=$False)] $IPAddress = "",
        [Parameter(Mandatory=$False)] $VMMac = "",
        [Parameter(Mandatory=$True)] $SCVMMConfig
    )

    $formattedMAC = Get-FormattedWACMAC -SCVMMConfig $SCVMMConfig
    $encodedPassword = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($($SCVMMConfig.SDNAdminPassword) + "AdministratorPassword"))
    $wacAnswerXML = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
<settings pass="specialize">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<ProductKey>$($SCVMMConfig.GUIProductKey)</ProductKey>
<ComputerName>$Hostname</ComputerName>
<RegisteredOwner>$ENV:adminUsername</RegisteredOwner>
</component>
<component name="Microsoft-Windows-TCPIP" processorArchitecture="wow64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<Ipv4Settings>
<DhcpEnabled>false</DhcpEnabled>
<Metric>20</Metric>
<RouterDiscoveryEnabled>true</RouterDiscoveryEnabled>
</Ipv4Settings>
<UnicastIpAddresses>
<IpAddress wcm:action="add" wcm:keyValue="1">$IPAddress</IpAddress>
</UnicastIpAddresses>
<Identifier>$formattedMAC</Identifier>
<Routes>
<Route wcm:action="add">
<Identifier>1</Identifier>
<NextHopAddress>$($SCVMMConfig.SDNLABRoute)</NextHopAddress>
</Route>
</Routes>
</Interface>
</Interfaces>
</component>
<component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<DNSServerSearchOrder>
<IpAddress wcm:action="add" wcm:keyValue="1">$($SCVMMConfig.SDNLABDNS)</IpAddress>
</DNSServerSearchOrder>
<Identifier>$formattedMAC</Identifier>
<DNSDomain>$($SCVMMConfig.SDNDomainFQDN)</DNSDomain>
<EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
</Interface>
</Interfaces>
</component>
<component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
<PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
<PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
</component>
<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<fDenyTSConnections>false</fDenyTSConnections>
</component>
<component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Identification>
<Credentials>
<Domain>$($SCVMMConfig.SDNDomainFQDN)</Domain>
<Password>$($SCVMMConfig.SDNAdminPassword)</Password>
<Username>Administrator</Username>
</Credentials>
<JoinDomain>$($SCVMMConfig.SDNDomainFQDN)</JoinDomain>
</Identification>
</component>
<component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<IEHardenAdmin>false</IEHardenAdmin>
<IEHardenUser>false</IEHardenUser>
</component>
</settings>
<settings pass="oobeSystem">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserAccounts>
<AdministratorPassword>
<PlainText>false</PlainText>
<Value>$encodedPassword</Value>
</AdministratorPassword>
</UserAccounts>
<TimeZone>UTC</TimeZone>
<OOBE>
<HideEULAPage>true</HideEULAPage>
<SkipUserOOBE>true</SkipUserOOBE>
<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
<HideOnlineAccountScreens>true</HideOnlineAccountScreens>
<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
<NetworkLocation>Work</NetworkLocation>
<ProtectYourPC>1</ProtectYourPC>
<HideLocalAccountScreen>true</HideLocalAccountScreen>
</OOBE>
</component>
<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserLocale>en-US</UserLocale>
<SystemLocale>en-US</SystemLocale>
<InputLocale>0409:00000409</InputLocale>
<UILanguage>en-US</UILanguage>
</component>
</settings>
<cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

    $components = @"
<component name="Microsoft-Windows-IE-ESC" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<IEHardenAdmin>false</IEHardenAdmin>
<IEHardenUser>false</IEHardenUser>
</component>
<component name="Microsoft-Windows-TCPIP" processorArchitecture="wow64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<Interfaces>
<Interface wcm:action="add">
<Identifier>$VMMac</Identifier>
<Ipv4Settings>
<DhcpEnabled>false</DhcpEnabled>
</Ipv4Settings>
<UnicastIpAddresses>
<IpAddress wcm:action="add" wcm:keyValue="1">$IPAddress</IpAddress>
</UnicastIpAddresses>
<Routes>
<Route wcm:action="add">
<Identifier>1</Identifier>
<NextHopAddress>$($SCVMMConfig.SDNLABRoute)</NextHopAddress>
<Prefix>0.0.0.0/0</Prefix>
<Metric>100</Metric>
</Route>
</Routes>
</Interface>
</Interfaces>
</component>
<component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DNSSuffixSearchOrder>
<DomainName wcm:action="add" wcm:keyValue="1">$($SCVMMConfig.SDNDomainFQDN)</DomainName>
</DNSSuffixSearchOrder>
<Interfaces>
<Interface wcm:action="add">
<DNSServerSearchOrder>
<IpAddress wcm:action="add" wcm:keyValue="1">$($SCVMMConfig.SDNLABDNS)</IpAddress>
</DNSServerSearchOrder>
<Identifier>$VMMac</Identifier>
<DisableDynamicUpdate>false</DisableDynamicUpdate>
<DNSDomain>$($SCVMMConfig.SDNDomainFQDN)</DNSDomain>
<EnableAdapterDomainNameRegistration>true</EnableAdapterDomainNameRegistration>
</Interface>
</Interfaces>
</component>
"@

    $azsmgmtProdKey = ""
    if ($IsMgmtVM) {
        $azsmgmtProdKey = "<ProductKey>$($SCVMMConfig.GUIProductKey)</ProductKey>"
    }
    $vmServicing = ""
    
    if ($IsRouterVM -or $IsDCVM) {
        $components = ""
        $optionXML = ""
        if ($IsRouterVM) {
            $optionXML = @"
<selection name="RemoteAccessServer" state="true" />
<selection name="RasRoutingProtocols" state="true" />
"@
        }
        if ($IsDCVM) {
            $optionXML = @"
<selection name="ADCertificateServicesRole" state="true" />
<selection name="CertificateServices" state="true" />
"@
        }
        $vmServicing = @"
<servicing>
<package action="configure">
<assemblyIdentity name="Microsoft-Windows-Foundation-Package" version="10.0.14393.0" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="" />
$optionXML</package>
</servicing>
"@
    }

    $UnattendXML = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
$vmServicing<settings pass="specialize">
<component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<DomainProfile_EnableFirewall>false</DomainProfile_EnableFirewall>
<PrivateProfile_EnableFirewall>false</PrivateProfile_EnableFirewall>
<PublicProfile_EnableFirewall>false</PublicProfile_EnableFirewall>
</component>
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<ComputerName>$Hostname</ComputerName>
$azsmgmtProdKey</component>
<component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<fDenyTSConnections>false</fDenyTSConnections>
</component>
<component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<UserLocale>en-us</UserLocale>
<UILanguage>en-us</UILanguage>
<SystemLocale>en-us</SystemLocale>
<InputLocale>en-us</InputLocale>
</component>
$components</settings>
<settings pass="oobeSystem">
<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<OOBE>
<HideEULAPage>true</HideEULAPage>
<SkipMachineOOBE>true</SkipMachineOOBE>
<SkipUserOOBE>true</SkipUserOOBE>
<HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
</OOBE>
<UserAccounts>
<AdministratorPassword>
<PlainText>false</PlainText>
<Value>$encodedPassword</Value>
</AdministratorPassword>
</UserAccounts>
</component>
</settings>
<cpi:offlineImage cpi:source="" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@
    if ($IsWACVM) {
        $UnattendXML = $wacAnswerXML
    }
    return $UnattendXML
}

function Restart-VMs {
    Param (
        $SCVMMConfig,
        [PSCredential]$Credential
    )
    foreach ($VM in $SCVMMConfig.NodeHostConfig) {
        Write-Host "Restarting VM: $($VM.Hostname)"
        Invoke-Command -VMName $VM.Hostname -Credential $Credential -ScriptBlock {
            Restart-Computer -Force
        }
    }
    Write-Host "Restarting VM: $($SCVMMConfig.MgmtHostConfig.Hostname)"
    Invoke-Command -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $Credential -ScriptBlock {
        Restart-Computer -Force
    }
    Start-Sleep -Seconds 30
}

function New-ManagementVM {
    Param (
        $Name,
        $VHDXPath,
        $VMSwitch,
        $SCVMMConfig
    )
    Write-Host "Creating VM $Name"
    # Create disks
    $VHDX1 = New-VHD -ParentPath $VHDXPath -Path "$($SCVMMConfig.HostVMPath)\$Name.vhdx" -Differencing 
    $VHDX2 = New-VHD -Path "$($SCVMMConfig.HostVMPath)\$Name-Data.vhdx" -SizeBytes 268435456000 -Dynamic

    # Create VM
    # Create Nested VM
    New-VM -Name $Name -MemoryStartupBytes $SCVMMConfig.AzSMGMTMemoryinGB -VHDPath $VHDX1.Path -SwitchName $VMSwitch -Generation 2 | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $VHDX2.Path
    Set-VM -Name $Name -ProcessorCount $SCVMMConfig.AzSMGMTProcCount -AutomaticStartAction Start | Out-Null

    Get-VMNetworkAdapter -VMName $Name | Rename-VMNetworkAdapter -NewName "SDN"
    Get-VMNetworkAdapter -VMName $Name | Set-VMNetworkAdapter -DeviceNaming On -StaticMacAddress  ("{0:D12}" -f ( Get-Random -Minimum 0 -Maximum 99999 ))
    Add-VMNetworkAdapter -VMName $Name -Name SDN2 -DeviceNaming On -SwitchName $VMSwitch
    $vmMac = (((Get-VMNetworkAdapter -Name SDN -VMName $Name).MacAddress) -replace '..(?!$)', '$&-')

    Get-VM $Name | Set-VMProcessor -ExposeVirtualizationExtensions $true
    Get-VM $Name | Set-VMMemory -DynamicMemoryEnabled $false
    Get-VM $Name | Get-VMNetworkAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On

    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN2 -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200  

    Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface"
    return $vmMac
}

function New-SCVMMNodeVM {
    param (
        $Name,
        $VHDXPath,
        $VMSwitch,
        $SCVMMConfig
    )
    Write-Host "Creating VM $Name"
    # Create disks
    $VHDX1 = New-VHD -ParentPath $VHDXPath -Path "$($SCVMMConfig.HostVMPath)\$Name.vhdx" -Differencing 
    $VHDX2 = New-VHD -Path "$($SCVMMConfig.HostVMPath)\$Name-Data.vhdx" -SizeBytes 268435456000 -Dynamic

    # Create Nested VM
    New-VM -Name $Name -MemoryStartupBytes $SCVMMConfig.NestedVMMemoryinGB -VHDPath $VHDX1.Path -SwitchName $VMSwitch -Generation 2 | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $VHDX2.Path


    Set-VM -Name $Name -ProcessorCount 20 -AutomaticStartAction Start
    Get-VMNetworkAdapter -VMName $Name | Rename-VMNetworkAdapter -NewName "SDN"
    Get-VMNetworkAdapter -VMName $Name | Set-VMNetworkAdapter -DeviceNaming On -StaticMacAddress  ("{0:D12}" -f ( Get-Random -Minimum 0 -Maximum 99999 ))
    # Add-VMNetworkAdapter -VMName $Name -Name SDN2 -DeviceNaming On -SwitchName $VMSwitch
    $vmMac = ((Get-VMNetworkAdapter -Name SDN -VMName $Name).MacAddress) -replace '..(?!$)', '$&-'

    Add-VMNetworkAdapter -VMName $Name -SwitchName $VMSwitch -DeviceNaming On -Name StorageA
    Add-VMNetworkAdapter -VMName $Name -SwitchName $VMSwitch -DeviceNaming On -Name StorageB

    Get-VM $Name | Set-VMProcessor -ExposeVirtualizationExtensions $true
    Get-VM $Name | Set-VMMemory -DynamicMemoryEnabled $false
    Get-VM $Name | Get-VMNetworkAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On

    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200
    # Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName SDN2 -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-200  
    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName StorageA -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-800
    Set-VMNetworkAdapterVlan -VMName $Name -VMNetworkAdapterName StorageB -Trunk -NativeVlanId 0 -AllowedVlanIdList 1-800 

    Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface"
    return $vmMac
}

function Set-MGMTVHDX {
    param (
        $VMMac,
        $SCVMMConfig
    )
    $DriveLetter = $($SCVMMConfig.HostVMPath).Split(':')
    $path = (("\\localhost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]) + "\" + $($SCVMMConfig.MgmtHostConfig.Hostname) + ".vhdx") 
    Write-Host "Performing offline installation of Hyper-V on $($SCVMMConfig.MgmtHostConfig.Hostname)"
    Install-WindowsFeature -Vhd $path -Name Hyper-V, RSAT-Hyper-V-Tools, Hyper-V-Powershell -Confirm:$false | Out-Null
    Start-Sleep -Seconds 20

    # Mount VHDX - bunch of kludgey logic in here to deal with different partition layouts on the GUI and SCVMM VHD images
    Write-Host "Mounting VHDX file at $path"
    [string]$MountedDrive = ""
    $partition = Mount-VHD -Path $path -Passthru | Get-Disk | Get-Partition -PartitionNumber 3
    if (!$partition.DriveLetter) {
        $MountedDrive = "X"
        $partition | Set-Partition -NewDriveLetter $MountedDrive
    }  
    else {
        $MountedDrive = $partition.DriveLetter
    }

    # Inject Answer File
    Write-Host "Injecting answer file to $path"
    $UnattendXML = GenerateAnswerFile -HostName $($SCVMMConfig.MgmtHostConfig.Hostname) -IsMgmtVM $true -IPAddress $SCVMMConfig.MgmtHostConfig.IP -VMMac $VMMac -SCVMMConfig $SCVMMConfig
    
    Write-Host "Mounted Disk Volume is: $MountedDrive" 
    $PantherDir = Get-ChildItem -Path ($MountedDrive + ":\Windows")  -Filter "Panther"
    if (!$PantherDir) { New-Item -Path ($MountedDrive + ":\Windows\Panther") -ItemType Directory -Force | Out-Null }

    Set-Content -Value $UnattendXML -Path ($MountedDrive + ":\Windows\Panther\Unattend.xml") -Force

    # Creating folder structure on AzSMGMT
    Write-Host "Creating VMs\Base folder structure on $($SCVMMConfig.MgmtHostConfig.Hostname)"
    New-Item -Path ($MountedDrive + ":\VMs\Base") -ItemType Directory -Force | Out-Null

    # Injecting configs into VMs
    Write-Host "Injecting files into $path"
    Copy-Item -Path "$Env:SCVMMDir\SCVMM-Config.psd1" -Destination ($MountedDrive + ":\") -Recurse -Force
    Copy-Item -Path $guiVHDXPath -Destination ($MountedDrive + ":\VMs\Base\GUI.vhdx") -Force
    Copy-Item -Path $azSSCVMMVHDXPath -Destination ($MountedDrive + ":\VMs\Base\AzSSCVMM.vhdx") -Force
    New-Item -Path ($MountedDrive + ":\") -Name "Windows Admin Center" -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$($SCVMMConfig.Paths["WACDir"])\*.msi" -Destination ($MountedDrive + ":\Windows Admin Center") -Recurse -Force  

    # Dismount VHDX
    Write-Host "Dismounting VHDX File at path $path"
    Dismount-VHD $path 
}

function Set-SCVMMNodeVHDX {
    param (
        $Hostname,
        $IPAddress,
        $VMMac,
        $SCVMMConfig
    )
    $DriveLetter = $($SCVMMConfig.HostVMPath).Split(':')
    $path = (("\\localhost\") + ($DriveLetter[0] + "$") + ($DriveLetter[1]) + "\" + $Hostname + ".vhdx") 
    Write-Host "Performing offline installation of Hyper-V on $Hostname"
    Install-WindowsFeature -Vhd $path -Name Hyper-V, RSAT-Hyper-V-Tools, Hyper-V-Powershell -Confirm:$false | Out-Null
    Start-Sleep -Seconds 5

    # Install necessary tools to converge 
    Write-Host "Installing and Configuring Failover ing on $Hostname"
    Install-WindowsFeature -Vhd $path -Name Failover-ing -IncludeAllSubFeature -IncludeManagementTools | Out-Null 
    Start-Sleep -Seconds 15

    Write-Host "Mounting VHDX file at $path"
    $partition = Mount-VHD -Path $path -Passthru | Get-Disk | Get-Partition -PartitionNumber 3
    if (!$partition.DriveLetter) {
        $MountedDrive = "Y"
        $partition | Set-Partition -NewDriveLetter $MountedDrive
    }   
    else {
        $MountedDrive = $partition.DriveLetter
    }

    Write-Host "Injecting answer file to $path"
    $UnattendXML = GenerateAnswerFile -HostName $Hostname -IPAddress $IPAddress -VMMac $VMMac -SCVMMConfig $SCVMMConfig
    Write-Host "Mounted Disk Volume is: $MountedDrive" 
    $PantherDir = Get-ChildItem -Path ($MountedDrive + ":\Windows")  -Filter "Panther"
    if (!$PantherDir) { New-Item -Path ($MountedDrive + ":\Windows\Panther") -ItemType Directory -Force | Out-Null }
    Set-Content -Value $UnattendXML -Path ($MountedDrive + ":\Windows\Panther\Unattend.xml") -Force

    New-Item -Path ($MountedDrive + ":\VHD") -ItemType Directory -Force | Out-Null
    Copy-Item -Path "$($SCVMMConfig.Paths.VHDDir)" -Destination ($MountedDrive + ":\VHD") -Recurse -Force            
    # Copy-Item -Path "$($SCVMMConfig.Paths.VHDDir)\Ubuntu.vhdx" -Destination ($MountedDrive + ":\VHD") -Recurse -Force

    # Dismount VHDX
    Write-Host "Dismounting VHDX File at path $path"
    Dismount-VHD $path  
}

function Set-DataDrives {
    param (
        $SCVMMConfig,
        [PSCredential]$Credential
    )
    $VMs = @()
    $VMs += $SCVMMConfig.MgmtHostConfig.Hostname
    foreach ($node in $SCVMMConfig.NodeHostConfig) {
        $VMs += $node.Hostname
    }
    foreach ($VM in $VMs) {
        Invoke-Command -VMName $VM -Credential $Credential -ScriptBlock {
            Set-Disk -Number 1 -IsOffline $false | Out-Null
                Initialize-Disk -Number 1 | Out-Null
                New-Partition -DiskNumber 1 -UseMaximumSize -AssignDriveLetter | Out-Null
                Format-Volume -DriveLetter D | Out-Null  
        }
    }
}

function Test-VMAvailable {
    param (
        $VMName,
        [PSCredential]$Credential
    )
    Invoke-Command -VMName $VMName -ScriptBlock { 
        $ErrorOccurred = $false
        do { 
            try { 
                $ErrorActionPreference = 'Stop'
                Get-VMHost | Out-Null
            } 
            catch { 
                $ErrorOccurred = $true
            } 
        } while ($ErrorOccurred -eq $true)
    } -Credential $Credential -ErrorAction Ignore
    Write-Host "VM $VMName is now online"
}

function Test-AllVMsAvailable
 {
    param (
        $SCVMMConfig,
        [PSCredential]$Credential
    )
    Write-Host "Testing whether VMs are available..."
    Test-VMAvailable -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $Credential
    foreach ($VM in $SCVMMConfig.NodeHostConfig) {
        Test-VMAvailable -VMName $VM.Hostname -Credential $Credential
    }
}
    
function New-NATSwitch {
    Param (
        $SCVMMConfig
    )
    Write-Host "Creating NAT Switch on switch $($SCVMMConfig.InternalSwitch)"
    Add-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -DeviceNaming On 
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname | Where-Object { $_.Name -match "Network" } | Connect-VMNetworkAdapter -SwitchName $SCVMMConfig.natHostVMSwitchName
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname | Where-Object { $_.Name -match "Network" } | Rename-VMNetworkAdapter -NewName "NAT"
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name NAT | Set-VMNetworkAdapter -MacAddressSpoofing On

    Add-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name PROVIDER -DeviceNaming On -SwitchName $SCVMMConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name PROVIDER | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name PROVIDER | Set-VMNetworkAdapterVlan -Access -VlanId $SCVMMConfig.providerVLAN | Out-Null    
   
    #Create VLAN 110 NIC in order for NAT to work from L3 Connections
    Add-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name VLAN110 -DeviceNaming On -SwitchName $SCVMMConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name VLAN110 | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name VLAN110 | Set-VMNetworkAdapterVlan -Access -VlanId $SCVMMConfig.vlan110VLAN | Out-Null

    #Create VLAN 200 NIC in order for NAT to work from L3 Connections
    Add-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name VLAN200 -DeviceNaming On -SwitchName $SCVMMConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name VLAN200 | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name VLAN200 | Set-VMNetworkAdapterVlan -Access -VlanId $SCVMMConfig.vlan200VLAN | Out-Null    

    #Create Simulated Internet NIC in order for NAT to work from L3 Connections
    Add-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name simInternet -DeviceNaming On -SwitchName $SCVMMConfig.InternalSwitch
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name simInternet | Set-VMNetworkAdapter -MacAddressSpoofing On
    Get-VMNetworkAdapter -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Name simInternet | Set-VMNetworkAdapterVlan -Access -VlanId $SCVMMConfig.simInternetVLAN | Out-Null
}  

function Set-NICs {
    Param (
        $SCVMMConfig,
        [PSCredential]$Credential
    )

    Invoke-Command -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $Credential -ScriptBlock {
        Get-NetAdapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC
        # Get-NetAdapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN2"}).Name) | Rename-NetAdapter -NewName FABRIC2
    }

    $int = 9
    foreach ($VM in $SCVMMConfig.NodeHostConfig) {
        $int++
        Write-Host "Setting NICs on VM $($VM.Hostname)"
        Invoke-Command -VMName $VM.Hostname -Credential $Credential -ArgumentList $SCVMMConfig, $VM -ScriptBlock {
            $SCVMMConfig = $args[0]
            $VM = $args[1]
            # Create IP Address of Storage Adapters
            $storageAIP = $VM.StorageAIP
            $storageBIP = $VM.StorageBIP

            # Set Name and IP Addresses on Storage Interfaces
            $storageNICs = Get-NetAdapterAdvancedProperty | Where-Object { $_.DisplayValue -match "Storage" }
            foreach ($storageNIC in $storageNICs) {
                Rename-NetAdapter -Name $storageNIC.Name -NewName  $storageNIC.DisplayValue        
            }
            $storageNICs = Get-Netadapter | Where-Object { $_.Name -match "Storage" }
            foreach ($storageNIC in $storageNICs) {
                If ($storageNIC.Name -eq 'StorageA') { New-NetIPAddress -InterfaceAlias $storageNIC.Name -IPAddress $storageAIP -PrefixLength 24 | Out-Null }  
                If ($storageNIC.Name -eq 'StorageB') { New-NetIPAddress -InterfaceAlias $storageNIC.Name -IPAddress $storageBIP -PrefixLength 24 | Out-Null }  
            }

            # Enable WinRM
            Write-Host "Enabling Windows Remoting in $env:COMPUTERNAME"
            Set-Item WSMan:\localhost\Client\TrustedHosts *  -Confirm:$false -Force
            Enable-PSRemoting | Out-Null

            Start-Sleep -Seconds 60

            # Rename non-storage adapters
            Get-NetAdapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN"}).Name) | Rename-NetAdapter -NewName FABRIC
            # Get-Netadapter ((Get-NetAdapterAdvancedProperty | Where-Object {$_.DisplayValue -eq "SDN2"}).Name) | Rename-NetAdapter -NewName FABRIC2

            # Enable CredSSP and MTU Settings
            Invoke-Command -ComputerName localhost -Credential $using:Credential -ScriptBlock {
                $fqdn = $Using:SCVMMConfig.SDNDomainFQDN

                Write-Host "Enabling CredSSP on $env:COMPUTERNAME"
                Enable-WSManCredSSP -Role Server -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer localhost -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer $env:COMPUTERNAME -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer $fqdn -Force
                Enable-WSManCredSSP -Role Client -DelegateComputer "*.$fqdn" -Force
                New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation `
                    -Name AllowFreshCredentialsWhenNTLMOnly -Force
                New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly `
                    -Name 1 -Value * -PropertyType String -Force 
            } -InDisconnectedSession | Out-Null
        }
    }
}

function Set-FabricNetwork {
    param (
        $SCVMMConfig,
        [PSCredential]$localCred
    )
    Start-Sleep -Seconds 20
    Write-Host "Configuring Fabric network on Management VM"
    Invoke-Command -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $localCred = $using:localCred
        $domainCred = $using:domainCred
        $SCVMMConfig = $using:SCVMMConfig

        $ErrorActionPreference = "Stop"

        # Disable Fabric2 Network Adapter
        # Write-Host "Disabling Fabric2 Adapter"
        # Get-NetAdapter FABRIC2 | Disable-NetAdapter -Confirm:$false | Out-Null
        
        # Enable WinRM on AzSMGMT
        Write-Host "Enabling PSRemoting on $env:COMPUTERNAME"
        Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force
        Enable-PSRemoting | Out-Null

        # Disable ServerManager Auto-Start
        Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask | Out-Null

        # Create Hyper-V Networking for AzSMGMT
        Import-Module Hyper-V 
        
        Write-Host "Creating VM Switch on $env:COMPUTERNAME"
        New-VMSwitch -AllowManagementOS $true -Name $SCVMMConfig.FabricSwitch -NetAdapterName $SCVMMConfig.FabricNIC -MinimumBandwidthMode None | Out-Null
        
        Write-Host "Configuring NAT on $env:COMPUTERNAME"
        $Prefix = ($SCVMMConfig.natSubnet.Split("/"))[1]
        $natIP = ($SCVMMConfig.natSubnet.TrimEnd("0./$Prefix")) + (".1")
        $provIP = $SCVMMConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24") + "254"
        $vlan200IP = $SCVMMConfig.BGPRouterIP_VLAN200.TrimEnd("1/24") + "250"
        $vlan110IP = $SCVMMConfig.BGPRouterIP_VLAN110.TrimEnd("1/24") + "250"
        $provGW = $SCVMMConfig.BGPRouterIP_ProviderNetwork.TrimEnd("/24")
        $provpfx = $SCVMMConfig.BGPRouterIP_ProviderNetwork.Split("/")[1]
        $vlan200pfx = $SCVMMConfig.BGPRouterIP_VLAN200.Split("/")[1]
        $vlan110pfx = $SCVMMConfig.BGPRouterIP_VLAN110.Split("/")[1]
        $simInternetIP = $SCVMMConfig.BGPRouterIP_SimulatedInternet.TrimEnd("1/24") + "254"
        $simInternetPFX = $SCVMMConfig.BGPRouterIP_SimulatedInternet.Split("/")[1]
        New-VMSwitch -SwitchName NAT -SwitchType Internal -MinimumBandwidthMode None | Out-Null
        New-NetIPAddress -IPAddress $natIP -PrefixLength $Prefix -InterfaceAlias "vEthernet (NAT)" | Out-Null
        New-NetNat -Name NATNet -InternalIPInterfaceAddressPrefix $SCVMMConfig.natSubnet | Out-Null

        Write-Host "Configuring Provider NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "PROVIDER" }
        Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
        New-NetIPAddress -InterfaceAlias "PROVIDER" -IPAddress $provIP -PrefixLength $provpfx | Out-Null

        Write-Host "Configuring VLAN200 NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
        Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
        New-NetIPAddress -InterfaceAlias "VLAN200" -IPAddress $vlan200IP -PrefixLength $vlan200pfx | Out-Null

        Write-Host "Configuring VLAN110 NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN110" }
        Rename-NetAdapter -name $NIC.name -newname "VLAN110" | Out-Null
        New-NetIPAddress -InterfaceAlias "VLAN110" -IPAddress $vlan110IP -PrefixLength $vlan110pfx | Out-Null

        Write-Host "Configuring simulatedInternet NIC on $env:COMPUTERNAME"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "simInternet" }
        Rename-NetAdapter -name $NIC.name -newname "simInternet" | Out-Null
        New-NetIPAddress -InterfaceAlias "simInternet" -IPAddress $simInternetIP -PrefixLength $simInternetPFX | Out-Null

        Write-Host "Configuring NAT"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "Network Adapter" -or $_.RegistryValue -eq "NAT" }
        Rename-NetAdapter -name $NIC.name -newname "Internet" | Out-Null 
        $internetIP = $SCVMMConfig.natHostSubnet.Replace("0/24", "5")
        $internetGW = $SCVMMConfig.natHostSubnet.Replace("0/24", "1")
        Start-Sleep -Seconds 15
        $internetIndex = (Get-NetAdapter | Where-Object { $_.Name -eq "Internet" }).ifIndex
        Start-Sleep -Seconds 15
        New-NetIPAddress -IPAddress $internetIP -PrefixLength 24 -InterfaceIndex $internetIndex -DefaultGateway $internetGW -AddressFamily IPv4 | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $internetIndex -ServerAddresses ($SCVMMConfig.natDNS) | Out-Null

        # Enable Large MTU
        Write-Host "Configuring MTU on all Adapters"
        Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -ne "Ethernet" } | Set-NetAdapterAdvancedProperty -RegistryValue $SCVMMConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"
        Start-Sleep -Seconds 15

        # Provision Public and Private VIP Route
        New-NetRoute -DestinationPrefix $SCVMMConfig.PublicVIPSubnet -NextHop $provGW -InterfaceAlias PROVIDER | Out-Null

        # Remove Gateway from Fabric NIC
        Write-Host "Removing Gateway from Fabric NIC" 
        $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -match "vSwitch-Fabric" }).InterfaceIndex
        Remove-NetRoute -InterfaceIndex $index -DestinationPrefix "0.0.0.0/0" -Confirm:$false
    }
}

function New-DCVM {
    Param (
        $SCVMMConfig,
        [PSCredential]$localCred,
        [PSCredential]$domainCred
    )
    Write-Host "Creating domain controller VM"
    $adminUser = $env:adminUsername
    $Unattend = GenerateAnswerFile -Hostname $SCVMMConfig.DCName -IsDCVM $true -SCVMMConfig $SCVMMConfig
    Invoke-Command -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $adminUser = $using:adminUser
        $SCVMMConfig = $using:SCVMMConfig
        $localCred = $using:localcred
        $domainCred = $using:domainCred
        $ParentDiskPath = "C:\VMs\Base\"
        $vmpath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $VMName = $SCVMMConfig.DCName

        # Create Virtual Machine
        Write-Host "Creating $VMName differencing disks"  
        New-VHD -ParentPath ($ParentDiskPath + $OSVHDX) -Path ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Differencing | Out-Null

        Write-Host "Creating $VMName virtual machine"
        New-VM -Name $VMName -VHDPath ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Path ($vmpath + $VMName) -Generation 2 | Out-Null

        Write-Host "Setting $VMName Memory"
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -StartupBytes $SCVMMConfig.MEM_DC -MaximumBytes $SCVMMConfig.MEM_DC -MinimumBytes 500MB | Out-Null

        Write-Host "Configuring $VMName's networking"
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter" | Out-Null
        Add-VMNetworkAdapter -VMName $VMName -Name $SCVMMConfig.DCName -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming 'On' | Out-Null
        
        Write-Host "Configuring $VMName's settings"
        Set-VMProcessor -VMName $VMName -Count 2 | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown | Out-Null

        # Inject Answer File
        Write-Host "Mounting and injecting answer file into the $VMName VM."        
        New-Item -Path "C:\TempMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempMount" -Index 1 -ImagePath ($vmpath + $VMName + '\' + $VMName + '.vhdx') | Out-Null
        Write-Host "Applying Unattend file to Disk Image..."
        New-Item -Path C:\TempMount\windows -ItemType Directory -Name Panther -Force | Out-Null
        Set-Content -Value $using:Unattend -Path "C:\TempMount\Windows\Panther\Unattend.xml"  -Force
        Write-Host "Dismounting Windows Image"
        Dismount-WindowsImage -Path "C:\TempMount" -Save | Out-Null
        Remove-Item "C:\TempMount" | Out-Null

        # Start Virtual Machine
        Write-Host "Starting Virtual Machine $VMName" 
        Start-VM -Name $VMName | Out-Null
        
        # Wait until the VM is restarted
        while ((Invoke-Command -VMName $VMName -Credential $using:localCred { "Test" } -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }

        Write-Host "Configuring $VMName and Installing Active Directory."
        Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $SCVMMConfig -ScriptBlock {
            $SCVMMConfig = $args[0]
            $DCName = $SCVMMConfig.DCName
            $IP = $SCVMMConfig.SDNLABDNS
            $PrefixLength = ($($SCVMMConfig.MgmtHostConfig.IP).Split("/"))[1]
            $SDNLabRoute = $SCVMMConfig.SDNLABRoute
            $DomainFQDN = $SCVMMConfig.SDNDomainFQDN
            $DomainNetBiosName = $DomainFQDN.Split(".")[0]

            Write-Host "Configuring NIC Settings for $DCName"
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq $DCName }
            Rename-NetAdapter -name $NIC.name -newname $DCName | Out-Null 
            New-NetIPAddress -InterfaceAlias $DCName -IPAddress $ip -PrefixLength $PrefixLength -DefaultGateway $SDNLabRoute | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias $DCName -ServerAddresses $IP | Out-Null
            Install-WindowsFeature -name AD-Domain-Services -IncludeManagementTools | Out-Null

            Write-Host "Configuring Trusted Hosts on $DCName"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force

            Write-Host "Installing Active Directory forest on $DCName."
            $SecureString = ConvertTo-SecureString $SCVMMConfig.SDNAdminPassword -AsPlainText -Force
            Install-ADDSForest -DomainName $DomainFQDN -DomainMode 'WinThreshold' -DatabasePath "C:\Domain" -DomainNetBiosName $DomainNetBiosName -SafeModeAdministratorPassword $SecureString -InstallDns -Confirm -Force -NoRebootOnCompletion # | Out-Null
        }

        Write-Host "Stopping $VMName"
        Get-VM $VMName | Stop-VM
        Write-Host "Starting $VMName"
        Get-VM $VMName | Start-VM 

        # Wait until DC is created and rebooted
        while ((Invoke-Command -VMName $VMName -Credential $domainCred -ArgumentList $SCVMMConfig.DCName { (Get-ADDomainController $args[0]).enabled } -ea SilentlyContinue) -ne $true) { Start-Sleep -Seconds 5 }

        Write-Host "Configuring User Accounts and Groups in Active Directory"
        Invoke-Command -VMName $VMName -Credential $domainCred -ArgumentList $SCVMMConfig, $adminUser -ScriptBlock {
            $SCVMMConfig = $args[0]
            $adminUser = $args[1]
            $SDNDomainFQDN = $SCVMMConfig.SDNDomainFQDN
            $SecureString = ConvertTo-SecureString $SCVMMConfig.SDNAdminPassword -AsPlainText -Force
            Set-ADDefaultDomainPasswordPolicy -ComplexityEnabled $false -Identity $SCVMMConfig.SDNDomainFQDN -MinPasswordLength 0

            $params = @{
                Name                  = 'NC Admin'
                GivenName             = 'NC'
                Surname               = 'Admin'
                SamAccountName        = 'NCAdmin'
                UserPrincipalName     = "NCAdmin@$SDNDomainFQDN"
                AccountPassword       = $SecureString
                Enabled               = $true
                ChangePasswordAtLogon = $false
                CannotChangePassword  = $true
                PasswordNeverExpires  = $true
            }
            New-ADUser @params
            
            $params = @{
                Name                  = $adminUser
                GivenName             = 'Jumpstart'
                Surname               = 'Jumpstart'
                SamAccountName        = $adminUser
                UserPrincipalName     = "$adminUser@$SDNDomainFQDN"
                AccountPassword       = $SecureString
                Enabled               = $true
                ChangePasswordAtLogon = $false
                CannotChangePassword  = $true
                PasswordNeverExpires  = $true
            }
            New-ADUser @params

            $params.Name = 'NC Client'
            $params.Surname = 'Client'
            $params.SamAccountName = 'NCClient'
            $params.UserPrincipalName = "NCClient@$SDNDomainFQDN" 
            New-ADUser @params

            New-ADGroup -name “NCAdmins” -groupscope Global
            New-ADGroup -name “NCClients” -groupscope Global

            Add-ADGroupMember "Domain Admins" "NCAdmin"
            Add-ADGroupMember "NCAdmins" "NCAdmin"
            Add-ADGroupMember "NCClients" "NCClient"
            Add-ADGroupMember "NCClients" $adminUser
            Add-ADGroupMember "NCAdmins" $adminUser
            Add-ADGroupMember "Domain Admins" $adminUser
            Add-ADGroupMember "NCAdmins" $adminUser
            Add-ADGroupMember "NCClients" $adminUser

            # Set Administrator Account Not to Expire
            Get-ADUser Administrator | Set-ADUser -PasswordNeverExpires $true  -CannotChangePassword $true
            Get-ADUser $adminUser | Set-ADUser -PasswordNeverExpires $true  -CannotChangePassword $true

            # Set DNS Forwarder
            Write-Host "Adding DNS Forwarders"
            Add-DnsServerForwarder $SCVMMConfig.natDNS

            # Create Enterprise CA 
            Write-Host "Installing and Configuring Active Directory Certificate Services and Certificate Templates"    
            Install-WindowsFeature -Name AD-Certificate -IncludeAllSubFeature -IncludeManagementTools | Out-Null
            Install-AdcsCertificationAuthority -CAtype 'EnterpriseRootCa' -CryptoProviderName 'ECDSA_P256#Microsoft Software Key Storage Provider' -KeyLength 256 -HashAlgorithmName 'SHA256' -ValidityPeriod 'Years' -ValidityPeriodUnits 10 -Confirm:$false | Out-Null

            # Give WebServer Template Enroll rights for Domain Computers
            $filter = "(CN=WebServer)"
            $ConfigContext = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $ConfigContext = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigContext"
            $ds = New-object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$ConfigContext", $filter)  
            $Template = $ds.Findone().GetDirectoryEntry() 

            if ($null -ne $Template) {
                $objUser = New-Object System.Security.Principal.NTAccount("Domain Computers") 
                $objectGuid = New-Object Guid 0e10c968-78fb-11d2-90d4-00c04f79dc55                     
                $ADRight = [System.DirectoryServices.ActiveDirectoryRights]"ExtendedRight"                     
                $ACEType = [System.Security.AccessControl.AccessControlType]"Allow"                     
                $ACE = New-Object System.DirectoryServices.ActiveDirectoryAccessRule -ArgumentList $objUser, $ADRight, $ACEType, $objectGuid                     
                $Template.ObjectSecurity.AddAccessRule($ACE)                     
                $Template.commitchanges()
            } 
 
            CMD.exe /c "certutil -setreg ca\ValidityPeriodUnits 8" | Out-Null
            Restart-Service CertSvc
            Start-Sleep -Seconds 60
 
            #Issue Certificate Template
            CMD.exe /c "certutil -SetCATemplates +WebServer"
        }
    }
}

function Set-DHCPServerOnDC {
    Param (
        $SCVMMConfig,
        [PSCredential]$domainCred,
        [PSCredential]$localCred
    )
    Invoke-Command -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        # Add NIC for VLAN200 for DHCP server (for use with Arc-enabled VMs)
        Add-VMNetworkAdapter -VMName $VMName -Name "VLAN200" -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming "On"
        Get-VMNetworkAdapter -VMName $VMName -Name "VLAN200" | Set-VMNetworkAdapterVLAN -Access -VlanId $SCVMMConfig.AKSVLAN
    }
    Write-Host "Configuring DHCP scope on DHCP server."
    # Set up DHCP scope for Arc resource bridge
    Invoke-Command -VMName $SCVMMConfig.DCName -Credential $using:domainCred -ArgumentList $SCVMMConfig -ScriptBlock {
        $SCVMMConfig = $args[0]
        
        Write-Host "Configuring NIC settings for $DCName VLAN200"
        $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
        Rename-NetAdapter -name $NIC.name -newname VLAN200 | Out-Null
        New-NetIPAddress -InterfaceAlias VLAN200 -IPAddress $SCVMMConfig.dcVLAN200IP -PrefixLength ($SCVMMConfig.AKSIPPrefix.split("/"))[1] -DefaultGateway $SCVMMConfig.AKSGWIP | Out-Null

        # Install DHCP feature
        Install-WindowsFeature DHCP -IncludeManagementTools
        CMD.exe /c "netsh dhcp add securitygroups"
        Restart-Service dhcpserver

        # Allow DHCP in domain
        $dnsName = $SCVMMConfig.DCName
        $fqdnsName = $SCVMMConfig.DCName + "." + $SCVMMConfig.SDNDomainFQDN
        Add-DhcpServerInDC -DnsName $fqdnsName -IPAddress $SCVMMConfig.dcVLAN200IP
        Get-DHCPServerInDC

        # Bind DHCP only to VLAN200 NIC
        Set-DhcpServerv4Binding -ComputerName $dnsName -InterfaceAlias $dnsName -BindingState $false
        Set-DhcpServerv4Binding -ComputerName $dnsName -InterfaceAlias VLAN200 -BindingState $true

        # Add DHCP scope for Resource bridge VMs
        Add-DhcpServerv4Scope -name "ResourceBridge" -StartRange $SCVMMConfig.rbVipStart -EndRange $SCVMMConfig.rbVipEnd -SubnetMask 255.255.255.0 -State Active
        $scope = Get-DhcpServerv4Scope
        Add-DhcpServerv4ExclusionRange -ScopeID $scope.ScopeID.IPAddressToString -StartRange $SCVMMConfig.rbDHCPExclusionStart -EndRange $SCVMMConfig.rbDHCPExclusionEnd
        Set-DhcpServerv4OptionValue -ComputerName $dnsName -ScopeId $scope.ScopeID.IPAddressToString -DnsServer $SCVMMConfig.SDNLABDNS -Router $SCVMMConfig.BGPRouterIP_VLAN200.Trim("/24")
    }
}

function New-RouterVM {
    Param (
        $SCVMMConfig,
        [PSCredential]$localCred
    )
    $Unattend = GenerateAnswerFile -Hostname $SCVMMConfig.BGPRouterName -IsRouterVM $true -SCVMMConfig $SCVMMConfig
    Invoke-Command -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $SCVMMConfig = $using:SCVMMConfig
        $localCred = $using:localcred
        $ParentDiskPath = "C:\VMs\Base\AzSSCVMM.vhdx"
        $vmpath = "D:\VMs\"
        $VMName = $SCVMMConfig.BGPRouterName
    
        # Create Host OS Disk
        Write-Host "Creating $VMName differencing disks"
        New-VHD -ParentPath $ParentDiskPath -Path ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Differencing | Out-Null
    
        # Create VM
        Write-Host "Creating the $VMName VM."
        New-VM -Name $VMName -VHDPath ($vmpath + $VMName + '\' + $VMName + '.vhdx') -Path ($vmpath + $VMName) -Generation 2 | Out-Null
    
        # Set VM Configuration
        Write-Host "Setting $VMName's VM Configuration"
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -StartupBytes $SCVMMConfig.MEM_BGP -MinimumBytes 500MB -MaximumBytes $SCVMMConfig.MEM_BGP | Out-Null
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter" | Out-Null 
        Set-VMProcessor -VMName $VMName -Count 2 | Out-Null
        Set-VM -Name $VMName -AutomaticStopAction ShutDown | Out-Null
    
        # Configure VM Networking
        Write-Host "Configuring $VMName's Networking"
        Add-VMNetworkAdapter -VMName $VMName -Name Mgmt -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name Provider -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name VLAN110 -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name VLAN200 -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming On
        Add-VMNetworkAdapter -VMName $VMName -Name SIMInternet -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming On
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName Provider -Access -VlanId $SCVMMConfig.providerVLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN110 -Access -VlanId $SCVMMConfig.vlan110VLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName VLAN200 -Access -VlanId $SCVMMConfig.vlan200VLAN
        Set-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName SIMInternet -Access -VlanId $SCVMMConfig.simInternetVLAN
        Add-VMNetworkAdapter -VMName $VMName -Name NAT -SwitchName NAT -DeviceNaming On   
    
        # Mount disk and inject Answer File
        Write-Host "Mounting Disk Image and Injecting Answer File into the $VMName VM." 
        New-Item -Path "C:\TempBGPMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempBGPMount" -Index 1 -ImagePath ($vmpath + $VMName + '\' + $VMName + '.vhdx') | Out-Null
        New-Item -Path C:\TempBGPMount\windows -ItemType Directory -Name Panther -Force | Out-Null  
        Set-Content -Value $using:Unattend -Path "C:\TempBGPMount\Windows\Panther\Unattend.xml" -Force
        
        # Enable remote access
        Write-Host "Enabling Remote Access"
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RasRoutingProtocols -All -LimitAccess | Out-Null
        Enable-WindowsOptionalFeature -Path C:\TempBGPMount -FeatureName RemoteAccessPowerShell -All -LimitAccess | Out-Null
        Write-Host "Dismounting Disk Image for $VMName VM." 
        Dismount-WindowsImage -Path "C:\TempBGPMount" -Save | Out-Null
        Remove-Item "C:\TempBGPMount"
        
        # Start the VM
        Write-Host "Starting $VMName VM."
        Start-VM -Name $VMName      
    
        # Wait for VM to be started
        while ((Invoke-Command -VMName $VMName -Credential $localcred { "Test" } -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 1 }    
    
        Write-Host "Configuring $VMName" 
        Invoke-Command -VMName $VMName -Credential $localCred -ArgumentList $SCVMMConfig -ScriptBlock {
            $SCVMMConfig = $args[0]
            $DNS = $SCVMMConfig.SDNLABDNS
            $natSubnet = $SCVMMConfig.natSubnet
            $natDNS = $SCVMMConfig.natSubnet
            $MGMTIP = $SCVMMConfig.BGPRouterIP_MGMT.Split("/")[0]
            $MGMTPFX = $SCVMMConfig.BGPRouterIP_MGMT.Split("/")[1]
            $PNVIP = $SCVMMConfig.BGPRouterIP_ProviderNetwork.Split("/")[0]
            $PNVPFX = $SCVMMConfig.BGPRouterIP_ProviderNetwork.Split("/")[1]
            $VLANIP = $SCVMMConfig.BGPRouterIP_VLAN200.Split("/")[0]
            $VLANPFX = $SCVMMConfig.BGPRouterIP_VLAN200.Split("/")[1]
            $VLAN110IP = $SCVMMConfig.BGPRouterIP_VLAN110.Split("/")[0]
            $VLAN110PFX = $SCVMMConfig.BGPRouterIP_VLAN110.Split("/")[1]
            $simInternetIP = $SCVMMConfig.BGPRouterIP_SimulatedInternet.Split("/")[0]
            $simInternetPFX = $SCVMMConfig.BGPRouterIP_SimulatedInternet.Split("/")[1]
    
            # Renaming NetAdapters and setting up the IPs inside the VM using CDN parameters
            Write-Host "Configuring $env:COMPUTERNAME's Networking"
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "Mgmt" }
            Rename-NetAdapter -name $NIC.name -newname "Mgmt" | Out-Null
            New-NetIPAddress -InterfaceAlias "Mgmt" -IPAddress $MGMTIP -PrefixLength $MGMTPFX | Out-Null
            Set-DnsClientServerAddress -InterfaceAlias “Mgmt” -ServerAddresses $DNS | Out-Null
            
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "PROVIDER" }
            Rename-NetAdapter -name $NIC.name -newname "PROVIDER" | Out-Null
            New-NetIPAddress -InterfaceAlias "PROVIDER" -IPAddress $PNVIP -PrefixLength $PNVPFX | Out-Null
            
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN200" }
            Rename-NetAdapter -name $NIC.name -newname "VLAN200" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN200" -IPAddress $VLANIP -PrefixLength $VLANPFX | Out-Null
            
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "VLAN110" }
            Rename-NetAdapter -name $NIC.name -newname "VLAN110" | Out-Null
            New-NetIPAddress -InterfaceAlias "VLAN110" -IPAddress $VLAN110IP -PrefixLength $VLAN110PFX | Out-Null
            
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "SIMInternet" }
            Rename-NetAdapter -name $NIC.name -newname "SIMInternet" | Out-Null
            New-NetIPAddress -InterfaceAlias "SIMInternet" -IPAddress $simInternetIP -PrefixLength $simInternetPFX | Out-Null      
    
            # Configure NAT
            $NIC = Get-NetAdapterAdvancedProperty -RegistryKeyWord "HyperVNetworkAdapterName" | Where-Object { $_.RegistryValue -eq "NAT" }
            Rename-NetAdapter -name $NIC.name -newname "NAT" | Out-Null
            $Prefix = ($natSubnet.Split("/"))[1]
            $natIP = ($natSubnet.TrimEnd("0./$Prefix")) + (".10")
            $natGW = ($natSubnet.TrimEnd("0./$Prefix")) + (".1")
            New-NetIPAddress -InterfaceAlias "NAT" -IPAddress $natIP -PrefixLength $Prefix -DefaultGateway $natGW | Out-Null
            if ($natDNS) {
                Set-DnsClientServerAddress -InterfaceAlias "NAT" -ServerAddresses $natDNS | Out-Null
            }
    
            # Configure Trusted Hosts
            Write-Host "Configuring Trusted Hosts on $env:COMPUTERNAME"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force
            
            # Installing Remote Access
            Write-Host "Installing Remote Access on $env:COMPUTERNAME" 
            Install-RemoteAccess -VPNType RoutingOnly | Out-Null
    
            # Adding a BGP Router to the VM
            # Write-Host "Creating BGP Router on $env:COMPUTERNAME"
            # Add-BgpRouter -BGPIdentifier $PNVIP -LocalASN $SCVMMConfig.BGPRouterASN -TransitRouting 'Enabled' -Id 1 -RouteReflector 'Enabled'

            # Configure BGP Peers - commented during refactor for 23h2
            # if ($SCVMMConfig.ConfigureBGPpeering -and $SCVMMConfig.ProvisionNC) {
            #     Write-Verbose "Peering future MUX/GWs"
            #     $Mux01IP = ($SCVMMConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "4"
            #     $GW01IP = ($SCVMMConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "5"
            #     $GW02IP = ($SCVMMConfig.BGPRouterIP_ProviderNetwork.TrimEnd("1/24")) + "6"
            #     $params = @{
            #         Name           = 'MUX01'
            #         LocalIPAddress = $PNVIP
            #         PeerIPAddress  = $Mux01IP
            #         PeerASN        = $SCVMMConfig.SDNASN
            #         OperationMode  = 'Mixed'
            #         PeeringMode    = 'Automatic'
            #     }
            #     Add-BgpPeer @params -PassThru
            #     $params.Name = 'GW01'
            #     $params.PeerIPAddress = $GW01IP
            #     Add-BgpPeer @params -PassThru
            #     $params.Name = 'GW02'
            #     $params.PeerIPAddress = $GW02IP
            #     Add-BgpPeer @params -PassThru    
            # }
    
            # Enable Large MTU
            Write-Host "Configuring MTU on all Adapters"
            Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Set-NetAdapterAdvancedProperty -RegistryValue $SCVMMConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"      
        }     
    }
}

function New-AdminCenterVM {
    Param (
        $SCVMMConfig,
        $localCred,
        $domainCred
    )
    $VMName = $SCVMMConfig.WACVMName
    $UnattendXML = GenerateAnswerFile -HostName $VMName -IsWACVM $true -IPAddress $SCVMMConfig.WACIP -VMMac $SCVMMConfig.WACMAC -SCVMMConfig $SCVMMConfig
    Invoke-Command -VMName AzSMGMT -Credential $localCred -ScriptBlock {
        $VMName = $using:VMName
        $ParentDiskPath = "C:\VMs\Base\"
        $VHDPath = "D:\VMs\"
        $OSVHDX = "GUI.vhdx"
        $BaseVHDPath = $ParentDiskPath + $OSVHDX
        $SCVMMConfig = $using:SCVMMConfig
        $localCred = $using:localCred
        $domainCred = $using:domainCred

        # Create Host OS Disk
        Write-Host "Creating $VMName differencing disks"
        New-VHD -ParentPath $BaseVHDPath -Path (($VHDPath) + ($VMName) + '\' + $VMName + (".vhdx")) -Differencing | Out-Null

        # Mount VHDX
        Import-Module DISM
        Write-Host "Mounting $VMName VHD"
        New-Item -Path "C:\TempWACMount" -ItemType Directory | Out-Null
        Mount-WindowsImage -Path "C:\TempWACMount" -Index 1 -ImagePath (($VHDPath) + ($VMName) + '\' + $VMName + (".vhdx")) | Out-Null

        # Copy Source Files
        Write-Host "Copying Application and Script Source Files to $VMName"
        Copy-Item 'C:\Windows Admin Center' -Destination C:\TempWACMount\ -Recurse -Force
        New-Item -Path C:\TempWACMount\VHDs -ItemType Directory -Force | Out-Null
        Copy-Item C:\VMs\Base\AzSSCVMM.vhdx -Destination C:\TempWACMount\VHDs -Force # I dont think this is needed
        Copy-Item C:\VMs\Base\GUI.vhdx  -Destination  C:\TempWACMount\VHDs -Force # I dont think this is needed

        # Create VM
        Write-Host "Provisioning the VM $VMName"
        New-VM -Name $VMName -VHDPath (($VHDPath) + ($VMName) + '\' + $VMName + (".vhdx")) -Path $VHDPath -Generation 2 | Out-Null
        Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -StartupBytes $SCVMMConfig.MEM_WAC -MaximumBytes $SCVMMConfig.MEM_WAC -MinimumBytes 500MB | Out-Null
        Set-VM -Name $VMName -AutomaticStartAction Start -AutomaticStopAction ShutDown | Out-Null
        Write-Host "Configuring $VMName networking"
        Remove-VMNetworkAdapter -VMName $VMName -Name "Network Adapter"
        Add-VMNetworkAdapter -VMName $VMName -Name "Fabric" -SwitchName $SCVMMConfig.FabricSwitch -DeviceNaming On
        Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $SCVMMConfig.WACMAC # Mac address is linked to the answer file required in next step

        # Apply custom Unattend.xml file
        New-Item -Path C:\TempWACMount\windows -ItemType Directory -Name Panther -Force | Out-Null    
        
        Write-Host "Mounting and Injecting Answer File into the $VMName VM." 
        Set-Content -Value $using:UnattendXML -Path "C:\TempWACMount\Windows\Panther\Unattend.xml" -Force
        Write-Host "Dismounting Disk"
        Dismount-WindowsImage -Path "C:\TempWACMount" -Save | Out-Null
        Remove-Item "C:\TempWACMount"

        Write-Host "Setting $VMName's VM Configuration"
        Set-VMProcessor -VMName $VMname -Count 4
        Set-VM -Name $VMName -AutomaticStopAction TurnOff

        Write-Host "Starting $VMName VM."
        Start-VM -Name $VMName

        # Wait until the VM is restarted
        while ((Invoke-Command -VMName $VMName -Credential $domainCred { "Test" } -ea SilentlyContinue) -ne "Test") { Start-Sleep -Seconds 5 }

        # Configure WAC
        Invoke-Command -VMName $VMName -Credential $domainCred -ArgumentList $SCVMMConfig, $VMName, $domainCred -ScriptBlock {
            $SCVMMConfig = $args[0]
            $VMName = $args[1]
            $domainCred = $args[2]
            Import-Module NetAdapter

            Write-Host "Enabling Remote Access on $VMName"
            Enable-WindowsOptionalFeature -FeatureName RasRoutingProtocols -All -LimitAccess -Online | Out-Null
            Enable-WindowsOptionalFeature -FeatureName RemoteAccessPowerShell -All -LimitAccess -Online | Out-Null

            Write-Host "Rename Network Adapter in $VMName" 
            Get-NetAdapter | Rename-NetAdapter -NewName Fabric
            Write-Host "Configuring MTU on all Adapters"
            Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Set-NetAdapterAdvancedProperty -RegistryValue $SCVMMConfig.SDNLABMTU -RegistryKeyword "*JumboPacket"   

            # Set Gateway
            $index = (Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.netconnectionid -eq "Fabric" }).InterfaceIndex
            $NetInterface = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.InterfaceIndex -eq $index }     
            $NetInterface.SetGateways($SCVMMConfig.SDNLABRoute) | Out-Null

            # Enable CredSSP
            Write-Host "Configuring WSMAN Trusted Hosts on $VMName"
            Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force | Out-Null
            Enable-WSManCredSSP -Role Client -DelegateComputer * -Force | Out-Null
            Enable-PSRemoting -force | Out-Null
            Enable-WSManCredSSP -Role Server -Force | Out-Null
            Enable-WSManCredSSP -Role Client -DelegateComputer localhost -Force | Out-Null
            Enable-WSManCredSSP -Role Client -DelegateComputer $env:COMPUTERNAME -Force | Out-Null
            Enable-WSManCredSSP -Role Client -DelegateComputer $SCVMMConfig.SDNDomainFQDN -Force | Out-Null
            Enable-WSManCredSSP -Role Client -DelegateComputer "*.$($SCVMMConfig.SDNDomainFQDN)" -Force | Out-Null
            New-Item -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation -Name AllowFreshCredentialsWhenNTLMOnly -Force | Out-Null
            New-ItemProperty -Path HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly -Name 1 -Value * -PropertyType String -Force | Out-Null

            $WACIP = $SCVMMConfig.WACIP.Split("/")[0]

            # Install RSAT-NetworkController
            $isAvailable = Get-WindowsFeature | Where-Object { $_.Name -eq 'RSAT-NetworkController' }
            if ($isAvailable) {
                Write-Host "Installing RSAT-NetworkController on $VMName"
                Import-Module ServerManager
                Install-WindowsFeature -Name RSAT-NetworkController -IncludeAllSubFeature -IncludeManagementTools | Out-Null
            }
            
            # Install Windows features
            Write-Host "Installing Hyper-V RSAT Tools on $VMName"
            Install-WindowsFeature -Name RSAT-Hyper-V-Tools -IncludeAllSubFeature -IncludeManagementTools | Out-Null
            Write-Host "Installing Active Directory RSAT Tools on $VMName"
            Install-WindowsFeature -Name  RSAT-ADDS -IncludeAllSubFeature -IncludeManagementTools | Out-Null
            Write-Host "Installing Failover ing RSAT Tools on $VMName"
            Install-WindowsFeature -Name  RSAT-ing-Mgmt, RSAT-ing-PowerShell -IncludeAllSubFeature -IncludeManagementTools | Out-Null
            Write-Host "Installing DNS Server RSAT Tools on $VMName"
            Install-WindowsFeature -Name RSAT-DNS-Server -IncludeAllSubFeature -IncludeManagementTools | Out-Null
            Install-RemoteAccess -VPNType RoutingOnly | Out-Null

            # Stop Server Manager from starting on boot
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager" -Name "DoNotOpenServerManagerAtLogon" -Value 1
            
            # Create BGP Router
            Add-BgpRouter -BGPIdentifier $WACIP -LocalASN $SCVMMConfig.WACASN -TransitRouting 'Enabled' -Id 1 -RouteReflector 'Enabled'

            $RequestInf = @"
[Version] 
Signature="`$Windows NT$"

[NewRequest] 
Subject = "CN=$($SCVMMConfig.WACVMName).$($SCVMMConfig.SDNDomainFQDN)"
Exportable = True
KeyLength = 2048                    
KeySpec = 1                     
KeyUsage = 0xA0               
MachineKeySet = True 
ProviderName = "Microsoft RSA SChannel Cryptographic Provider" 
ProviderType = 12 
SMIME = FALSE 
RequestType = CMC
FriendlyName = "SCVMM Windows Admin Cert"

[Strings] 
szOID_SUBJECT_ALT_NAME2 = "2.5.29.17" 
szOID_ENHANCED_KEY_USAGE = "2.5.29.37" 
szOID_PKIX_KP_SERVER_AUTH = "1.3.6.1.5.5.7.3.1" 
szOID_PKIX_KP_CLIENT_AUTH = "1.3.6.1.5.5.7.3.2"
[Extensions] 
%szOID_SUBJECT_ALT_NAME2% = "{text}dns=$($SCVMMConfig.WACVMName).$($SCVMMConfig.SDNDomainFQDN)" 
%szOID_ENHANCED_KEY_USAGE% = "{text}%szOID_PKIX_KP_SERVER_AUTH%,%szOID_PKIX_KP_CLIENT_AUTH%"
[RequestAttributes] 
CertificateTemplate= WebServer
"@

            New-Item C:\WACCert -ItemType Directory -Force | Out-Null
            Set-Content -Value $RequestInf -Path C:\WACCert\WACCert.inf -Force | Out-Null

            Register-PSSessionConfiguration -Name 'Microsoft.SDNNested' -RunAsCredential $domainCred -MaximumReceivedDataSizePerCommandMB 1000 -MaximumReceivedObjectSizeMB 1000
            Write-Host "Requesting and installing SSL Certificate on $using:VMName" 
            Invoke-Command -ComputerName $VMName -ConfigurationName 'Microsoft.SDNNested' -Credential $domainCred -ArgumentList $SCVMMConfig -ScriptBlock {
                $SCVMMConfig = $args[0]
                # Get the CA Name
                $CertDump = certutil -dump
                $ca = ((((($CertDump.Replace('`', "")).Replace("'", "")).Replace(":", "=")).Replace('\', "")).Replace('"', "") | ConvertFrom-StringData).Name
                $CertAuth = $SCVMMConfig.SDNDomainFQDN + '\' + $ca

                Write-Host "CA is: $ca"
                Write-Host "Certificate Authority is: $CertAuth"
                Write-Host "Certdump is $CertDump"

                # Request and Accept SSL Certificate
                Set-Location C:\WACCert
                certreq -q -f -new WACCert.inf WACCert.req
                certreq -q -config $CertAuth -attrib "CertificateTemplate:webserver" -submit WACCert.req  WACCert.cer 
                certreq -q -accept WACCert.cer
                certutil -q -store my

                Set-Location 'C:\'
                Remove-Item C:\WACCert -Recurse -Force

            } -Authentication Credssp

            # Install Windows Admin Center
            $pfxThumbPrint = (Get-ChildItem -Path Cert:\LocalMachine\my | Where-Object { $_.FriendlyName -match "SCVMM Windows Admin Cert" }).Thumbprint
            Write-Host "Thumbprint: $pfxThumbPrint"
            Write-Host "WACPort: $($SCVMMConfig.WACport)"
            $WindowsAdminCenterGateway = "https://$($SCVMMConfig.WACVMName)." + $SCVMMConfig.SDNDomainFQDN
            Write-Host $WindowsAdminCenterGateway
            Write-Host "Installing and Configuring Windows Admin Center"
            $PathResolve = Resolve-Path -Path 'C:\Windows Admin Center\*.msi'
            $arguments = "/qn /L*v C:\log.txt SME_PORT=$($SCVMMConfig.WACport) SME_THUMBPRINT=$pfxThumbPrint SSL_CERTIFICATE_OPTION=installed SME_URL=$WindowsAdminCenterGateway"
            Start-Process -FilePath $PathResolve -ArgumentList $arguments -PassThru | Wait-Process

            # Install Chocolatey
            Write-Host "Installing Chocolatey"
            Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            Start-Sleep -Seconds 10

            # Install Azure PowerShell
            Write-Host 'Installing Az PowerShell'
            $expression = "choco install az.powershell -y --limit-output"
            Invoke-Expression $expression
    
            # Create Shortcut for Hyper-V Manager
            Write-Host "Creating Shortcut for Hyper-V Manager"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\Public\Desktop"

            # Create Shortcut for Failover- Manager
            Write-Host "Creating Shortcut for Failover- Manager"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Failover  Manager.lnk" -Destination "C:\Users\Public\Desktop"

            # Create Shortcut for DNS
            Write-Host "Creating Shortcut for DNS Manager"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\DNS.lnk" -Destination "C:\Users\Public\Desktop"

            # Create Shortcut for Active Directory Users and Computers
            Write-Host "Creating Shortcut for AD Users and Computers"
            Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Active Directory Users and Computers.lnk" -Destination "C:\Users\Public\Desktop"
    
            # Set Network Profiles
            Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq "Public" } | Set-NetConnectionProfile -NetworkCategory Private | Out-Null    
    
            # Disable Automatic Updates
            $WUKey = "HKLM:\software\Policies\Microsoft\Windows\WindowsUpdate"
            New-Item -Path $WUKey -Force | Out-Null
            New-ItemProperty -Path $WUKey -Name AUOptions -PropertyType Dword -Value 2 -Force | Out-Null  

            # Install Kubectl
            Write-Host 'Installing kubectl'
            $expression = "choco install kubernetes-cli -y --limit-output"
            Invoke-Expression $expression

            # Create a shortcut for Windows Admin Center
            Write-Host "Creating Shortcut for Windows Admin Center"
            if ($SCVMMConfig.WACport -ne "443") { $TargetPath = "https://$($SCVMMConfig.WACVMName)." + $SCVMMConfig.SDNDomainFQDN + ":" + $SCVMMConfig.WACport }
            else { $TargetPath = "https://$($SCVMMConfig.WACVMName)." + $SCVMMConfig.SDNDomainFQDN }
            $ShortcutFile = "C:\Users\Public\Desktop\Windows Admin Center.url"
            $WScriptShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WScriptShell.CreateShortcut($ShortcutFile)
            $Shortcut.TargetPath = $TargetPath
            $Shortcut.Save()

            # Disable Edge 'First Run' Setup
            $edgePolicyRegistryPath  = 'HKLM:SOFTWARE\Policies\Microsoft\Edge'
            $desktopSettingsRegistryPath = 'HKCU:SOFTWARE\Microsoft\Windows\Shell\Bags\1\Desktop'
            $firstRunRegistryName  = 'HideFirstRunExperience'
            $firstRunRegistryValue = '0x00000001'
            $savePasswordRegistryName = 'PasswordManagerEnabled'
            $savePasswordRegistryValue = '0x00000000'
            $autoArrangeRegistryName = 'FFlags'
            $autoArrangeRegistryValue = '1075839525'

            if (-NOT (Test-Path -Path $edgePolicyRegistryPath)) {
                New-Item -Path $edgePolicyRegistryPath -Force | Out-Null
            }
            if (-NOT (Test-Path -Path $desktopSettingsRegistryPath)) {
                New-Item -Path $desktopSettingsRegistryPath -Force | Out-Null
            }

            New-ItemProperty -Path $edgePolicyRegistryPath -Name $firstRunRegistryName -Value $firstRunRegistryValue -PropertyType DWORD -Force
            New-ItemProperty -Path $edgePolicyRegistryPath -Name $savePasswordRegistryName -Value $savePasswordRegistryValue -PropertyType DWORD -Force
            Set-ItemProperty -Path $desktopSettingsRegistryPath -Name $autoArrangeRegistryName -Value $autoArrangeRegistryValue -Force            
        }
    }
}

function Test-InternetConnect {
    $testIP = $SCVMMConfig.natDNS
    $ErrorActionPreference = "Stop"  
    $intConnect = Test-NetConnection -ComputerName $testip -Port 53

    if (!$intConnect.TcpTestSucceeded) {
        throw "Unable to connect to DNS by pinging $($SCVMMConfig.natDNS) - Network access to this IP is required."
    }
}

function Set-HostNAT {
    param (
        $SCVMMConfig
    )

    $switchExist = Get-NetAdapter | Where-Object { $_.Name -match $SCVMMConfig.natHostVMSwitchName }
    if (!$switchExist) {
        Write-Host "Creating NAT Switch: $($SCVMMConfig.natHostVMSwitchName)"
        # Create Internal VM Switch for NAT
        New-VMSwitch -Name $SCVMMConfig.natHostVMSwitchName -SwitchType Internal | Out-Null

        Write-Host "Applying IP Address to NAT Switch: $($SCVMMConfig.natHostVMSwitchName)"
        # Apply IP Address to new Internal VM Switch
        $intIdx = (Get-NetAdapter | Where-Object { $_.Name -match $SCVMMConfig.natHostVMSwitchName }).ifIndex
        $natIP = $SCVMMConfig.natHostSubnet.Replace("0/24", "1")
        New-NetIPAddress -IPAddress $natIP -PrefixLength 24 -InterfaceIndex $intIdx | Out-Null

        # Create NetNAT
        Write-Host "Creating new Net NAT"
        New-NetNat -Name $SCVMMConfig.natHostVMSwitchName  -InternalIPInterfaceAddressPrefix $SCVMMConfig.natHostSubnet | Out-Null
    }
}

function Set-SCVMMDeployPrereqs {
    param (
        $SCVMMConfig,
        [PSCredential]$localCred,
        [PSCredential]$domainCred
    )
    Invoke-Command -VMName $SCVMMConfig.MgmtHostConfig.Hostname -Credential $localCred -ScriptBlock {
        $SCVMMConfig = $using:SCVMMConfig
        $localCred = $using:localcred
        $domainCred = $using:domainCred
        Invoke-Command -VMName $SCVMMConfig.DCName -Credential $domainCred -ArgumentList $SCVMMConfig -ScriptBlock {
            $SCVMMConfig = $args[0]
            $domainCredNoDomain = new-object -typename System.Management.Automation.PSCredential `
                -argumentlist ($SCVMMConfig.LCMDeployUsername), (ConvertTo-SecureString $SCVMMConfig.SDNAdminPassword -AsPlainText -Force)
            
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser
            Install-Module AsSCVMMADArtifactsPreCreationTool -Repository PSGallery -Force -Confirm:$false
            $domainName = $SCVMMConfig.SDNDomainFQDN.Split('.')
            $ouName = "OU=$($SCVMMConfig.LCMADOUName)"
            foreach ($name in $domainName) {
                $ouName += ",DC=$name"
            }
            $nodes = @()
            foreach ($node in $SCVMMConfig.NodeHostConfig) {
                $nodes += $node.Hostname.ToString()
            }
            Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
            $deploymentPrefix = $SCVMMConfig.LCMDeploymentPrefix
            New-SCVMMAdObjectsPreCreation -Deploy -AzureStackLCMUserCredential $domainCredNoDomain -AsSCVMMOUName $ouName -AsSCVMMPhysicalNodeList $nodes -DomainFQDN $SCVMMConfig.SDNDomainFQDN -AsSCVMMName $SCVMMConfig.Name -AsSCVMMDeploymentPrefix $deploymentPrefix
        }
    }
    
    foreach ($node in $SCVMMConfig.NodeHostConfig) {
        Invoke-Command -VMName $node.Hostname -Credential $localCred -ArgumentList $env:subscriptionId, $env:spnTenantId, $env:spnClientID, $env:spnClientSecret, $env:resourceGroup -ScriptBlock {
            $subId = $args[0]
            $tenantId = $args[1]
            $clientId = $args[2]
            $clientSecret = $args[3]
            $resourceGroup = $args[4]
    
            # Prep nodes for Azure Arc onboarding
            winrm quickconfig -quiet
            netsh advfirewall firewall add rule name="ICMP Allow incoming V4 echo request" protocol=icmpv4:8,any dir=in action=allow
    
            # Register PSGallery as a trusted repo
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
            Register-PSRepository -Default -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    
            #Install Arc registration script from PSGallery 
            Install-Module AzsSCVMM.ARCinstaller -Force
    
            #Install required PowerShell modules in your node for registration
            Install-Module Az.Accounts -Force
            Install-Module Az.ConnectedMachine -Force
            Install-Module Az.Resources -Force
            $azureAppCred = (New-Object System.Management.Automation.PSCredential $clientId, (ConvertTo-SecureString -String $clientSecret -AsPlainText -Force))
            Connect-AzAccount -ServicePrincipal -SubscriptionId $subId -TenantId $tenantId -Credential $azureAppCred
            $armtoken = Get-AzAccessToken

            # Workaround for BITS transfer issue
            Get-NetAdapter StorageA | Disable-NetAdapter -Confirm:$false | Out-Null
            Get-NetAdapter StorageB | Disable-NetAdapter -Confirm:$false | Out-Null
    
            #Invoke the registration script. For this release, only eastus region is supported.
            Invoke-AzStackSCVMMArcInitialization -SubscriptionID $subId -ResourceGroup $resourceGroup -TenantID $tenantId -Region eastus -Cloud "AzureCloud" -ArmAccessToken $armtoken.Token -AccountID $clientId
            
            Get-NetAdapter StorageA | Enable-NetAdapter -Confirm:$false | Out-Null
            Get-NetAdapter StorageB | Enable-NetAdapter -Confirm:$false | Out-Null
        }
    }
}

#endregion
   
#region Main
$guiVHDXPath = $SCVMMConfig.guiVHDXPath
$azSSCVMMVHDXPath = $SCVMMConfig.azSSCVMMVHDXPath
$HostVMPath = $SCVMMConfig.HostVMPath
$InternalSwitch = $SCVMMConfig.InternalSwitch
$natDNS = $SCVMMConfig.natDNS
$natSubnet = $SCVMMConfig.natSubnet

Import-Module Hyper-V

$VerbosePreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
$WarningPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Create paths
foreach ($path in $SCVMMConfig.Paths.GetEnumerator()) {
    Write-Host "Creating $($path.Key) path at $($path.Value)"
    New-Item -Path $path.Value -ItemType Directory -Force | Out-Null
}

# Download SCVMM VHDs
Write-Host "[Build  - Step 1/10] Downloading SCVMM VHDs" -ForegroundColor Green
BITSRequest -Params @{'Uri'='https://aka.ms/VHD-HCIBox-Mgmt-Pro'; 'Filename'="$($SCVMMConfig.Paths.VHDDir)\AZSSCVMM.vhdx" }
BITSRequest -Params @{'Uri'='https://aka.ms/VHD-HCIBox-Mgmt-Prod'; 'Filename'="$($SCVMMConfig.Paths.VHDDir)\AZSSCVMM.sha256" }
$checksum = Get-FileHash -Path "$($SCVMMConfig.Paths.VHDDir)\AZSSCVMM.vhdx"
$hash = Get-Content -Path "$($SCVMMConfig.Paths.VHDDir)\AZSSCVMM.sha256"
if ($checksum.Hash -eq $hash) {
    Write-Host "AZSCHI.vhdx has valid checksum. Continuing..."
}
else {
    Write-Error "AZSCHI.vhdx is corrupt. Aborting deployment. Re-run C:\SCVMM\SCVMMLogonScript.ps1 to retry"
    throw 
}
BITSRequest -Params @{'Uri'='https://aka.ms/VHD-HCIBox-Mgmt-Pro'; 'Filename'="$($SCVMMConfig.Paths.VHDDir)\GUI.vhdx"}
BITSRequest -Params @{'Uri'='https://aka.ms/VHD-HCIBox-Mgmt-Pro'; 'Filename'="$($SCVMMConfig.Paths.VHDDir)\GUI.sha256" }
$checksum = Get-FileHash -Path "$($SCVMMConfig.Paths.VHDDir)\GUI.vhdx"
$hash = Get-Content -Path "$($SCVMMConfig.Paths.VHDDir)\GUI.sha256"
if ($checksum.Hash -eq $hash) {
    Write-Host "GUI.vhdx has valid checksum. Continuing..."
}
else {
    Write-Error "GUI.vhdx is corrupt. Aborting deployment. Re-run C:\SCVMM\SCVMMLogonScript.ps1 to retry"
    throw 
}
# BITSRequest -Params @{'Uri'='https://partner-images.canonical.com/hyper-v/desktop/focal/current/ubuntu-focal-hyperv-amd64-ubuntu-desktop-hyperv.vhdx.zip'; 'Filename'="$($SCVMMConfig.Paths.VHDDir)\Ubuntu.vhdx.zip"}
# Expand-Archive -Path "$($SCVMMConfig.Paths.VHDDir)\Ubuntu.vhdx.zip" -DestinationPath $($SCVMMConfig.Paths.VHDDir)
# Move-Item -Path "$($SCVMMConfig.Paths.VHDDir)\livecd.ubuntu-desktop-hyperv.vhdx" -Destination "$($SCVMMConfig.Paths.VHDDir)\Ubuntu.vhdx"

# Set credentials
$localCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist "Administrator", (ConvertTo-SecureString $SCVMMConfig.SDNAdminPassword -AsPlainText -Force)

$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SCVMMConfig.SDNDomainFQDN.Split(".")[0]) +"\Administrator"), (ConvertTo-SecureString $SCVMMConfig.SDNAdminPassword -AsPlainText -Force)

# Enable PSRemoting
Write-Host "[Build  - Step 2/10] Preparing Azure VM virtualization host..." -ForegroundColor Green
Write-Host "Enabling PS Remoting on client..."
Enable-PSRemoting
set-item WSMan:localhost\client\trustedhosts -value * -Force
Enable-WSManCredSSP -Role Client -DelegateComputer "*.$($SCVMMConfig.SDNDomainFQDN)" -Force

###############################################################################
# Configure Hyper-V host
###############################################################################
Write-Host "Checking internet connectivity"
Test-InternetConnect

Write-Host "Creating Internal Switch"
New-InternalSwitch -SCVMMConfig $SCVMMConfig

Write-Host "Creating NAT Switch"
Set-HostNAT -SCVMMConfig $SCVMMConfig

Write-Host "Configuring SCVMM-Client Hyper-V host"
Set-VMHost -VirtualHardDiskPath $HostVMPath -VirtualMachinePath $HostVMPath -EnableEnhancedSessionMode $true

Write-Host "Copying VHDX Files to Host virtualization drive"
$guipath = "$HostVMPath\GUI.vhdx"
$SCVMMpath = "$HostVMPath\AzSSCVMM.vhdx"
Copy-Item -Path $SCVMMConfig.guiVHDXPath -Destination $guipath -Force | Out-Null
Copy-Item -Path $SCVMMConfig.azSSCVMMVHDXPath -Destination $SCVMMpath -Force | Out-Null

################################################################################
# Create the three nested Virtual Machines 
################################################################################
# First create the Management VM (AzSMGMT)
Write-Host "[Build  - Step 3/10] Creating Management VM (AzSMGMT)..." -ForegroundColor Green
$mgmtMac = New-ManagementVM -Name $($SCVMMConfig.MgmtHostConfig.Hostname) -VHDXPath "$HostVMPath\GUI.vhdx" -VMSwitch $InternalSwitch -SCVMMConfig $SCVMMConfig
Set-MGMTVHDX -VMMac $mgmtMac -SCVMMConfig $SCVMMConfig

# Create the SCVMM host node VMs
Write-Host "[Build  - Step 4/10] Creating SCVMM node VMs (AzSHOSTx)..." -ForegroundColor Green
foreach ($VM in $SCVMMConfig.NodeHostConfig) {
    $mac = New-SCVMMNodeVM -Name $VM.Hostname -VHDXPath $SCVMMpath -VMSwitch $InternalSwitch -SCVMMConfig $SCVMMConfig
    Set-SCVMMNodeVHDX -HostName $VM.Hostname -IPAddress $VM.IP -VMMac $mac  -SCVMMConfig $SCVMMConfig
}
    
# Start Virtual Machines
Write-Host "[Build  - Step 5/10] Starting VMs..." -ForegroundColor Green
Write-Host "Starting VM: $($SCVMMConfig.MgmtHostConfig.Hostname)"
Start-VM -Name $SCVMMConfig.MgmtHostConfig.Hostname
foreach ($VM in $SCVMMConfig.NodeHostConfig) {
    Write-Host "Starting VM: $($VM.Hostname)"
    Start-VM -Name $VM.Hostname
}

#######################################################################################
# Prep the virtualization environment
#######################################################################################
Write-Host "[Build  - Step 6/10] Configuring host networking and storage..." -ForegroundColor Green
# Wait for AzSHOSTs to come online
Test-AllVMsAvailable -SCVMMConfig $SCVMMConfig -Credential $localCred
Start-Sleep -Seconds 60

# Format and partition data drives
Set-DataDrives -SCVMMConfig $SCVMMConfig -Credential $localCred
    
# Configure networking
Set-NICs -SCVMMConfig $SCVMMConfig -Credential $localCred
    
# Restart Machines
Restart-VMs -SCVMMConfig $SCVMMConfig -Credential $localCred
    
# Wait for AzSHOSTs to come online
Test-AllVMsAvailable -SCVMMConfig $SCVMMConfig -Credential $localCred

# Create NAT Virtual Switch on AzSMGMT
New-NATSwitch -SCVMMConfig $SCVMMConfig

# Configure fabric network on AzSMGMT
Set-FabricNetwork -SCVMMConfig $SCVMMConfig -localCred $localCred

#######################################################################################
# Provision the router, domain controller, and WAC VMs and join the hosts to the domain
#######################################################################################
# Provision Router VM on AzSMGMT
Write-Host "[Build  - Step 7/10] Build router VM..." -ForegroundColor Green
New-RouterVM -SCVMMConfig $SCVMMConfig -localCred $localCred

# Provision Domain controller VM on AzSMGMT
Write-Host "[Build  - Step 8/10] Building Domain Controller VM..." -ForegroundColor Green
New-DCVM -SCVMMConfig $SCVMMConfig -localCred $localCred -domainCred $domainCred

# Provision Admincenter VM
# Write-Host "[Build  - Step 9/12] Building Windows Admin Center gateway server VM... (skipping step)" -ForegroundColor Green
#New-AdminCenterVM -SCVMMConfig $SCVMMConfig -localCred $localCred -domainCred $domainCred

#######################################################################################
# Prepare the  for deployment
#######################################################################################
# New-S2D -SCVMMConfig $SCVMMConfig -domainCred $domainCred
Write-Host "[Build  - Step 9/10] Preparing SCVMM  Azure deployment..." -ForegroundColor Green
Set-SCVMMDeployPrereqs -SCVMMConfig $SCVMMConfig -localCred $localCred -domainCred $domainCred

#  complete. Finish up and add RDP Link to Desktop to WAC machine.
Write-Host "[Build  - Step 10/10] Tidying up..." -ForegroundColor Green

$endtime = Get-Date
$timeSpan = New-TimeSpan -Start $starttime -End $endtime
Write-Host
Write-Host "Successfully deployed SCVMM infrastructure." -ForegroundColor Green
Write-Host "Infrastructure deployment time was $($timeSpan.Hours):$($timeSpan.Minutes) (hh:mm)." -ForegroundColor Green

Stop-Transcript 

#endregion    