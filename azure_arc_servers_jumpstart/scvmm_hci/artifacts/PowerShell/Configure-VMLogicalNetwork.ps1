$WarningPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop" 
$ProgressPreference = 'SilentlyContinue'

# Set paths
$Env:SCVMMDir = "C:\SCVMM"

# Import Configuration Module
$SCVMMConfig = Import-PowerShellDataFile -Path $Env:SCVMMConfigFile
Start-Transcript -Path "$($SCVMMConfig.Paths.LogsDir)\Configure-VMLogicalNetwork.log"

$domainCred = new-object -typename System.Management.Automation.PSCredential `
    -argumentlist (($SCVMMConfig.SDNDomainFQDN.Split(".")[0]) +"\Administrator"), (ConvertTo-SecureString $SCVMMConfig.SDNAdminPassword -AsPlainText -Force)

$subId = $env:subscriptionId
$rg = $env:resourceGroup
$spnClientId = $env:spnClientId
$spnSecret = $env:spnClientSecret
$spnTenantId = $env:spnTenantId
$location = "eastus"
$customLocName = $SCVMMConfig.rbCustomLocationName

# Create logical networks
Invoke-Command -ComputerName "$($SCVMMConfig.NodeHostConfig[0].Hostname).$($SCVMMConfig.SDNDomainFQDN)" -Credential $domainCred -Authentication CredSSP -ArgumentList $SCVMMConfig -ScriptBlock {
    $SCVMMConfig = $args[0]
    az login --service-principal --username $using:spnClientID --password=$using:spnSecret --tenant $using:spnTenantId
    az config set extension.use_dynamic_install=yes_without_prompt
    $customLocationID=(az customlocation show --resource-group $using:rg --name $using:customLocName --query id -o tsv)

    $switchName='"ConvergedSwitch(hci)"'
    $lnetName = "SCVMM-vm-lnet-vlan200"
    $addressPrefixes = $SCVMMConfig.vmIpPrefix
    $gateway = $SCVMMConfig.vmGateway
    $dnsServers = $SCVMMConfig.vmDNS
    $vlanid = $SCVMMConfig.vmVLAN

    az stack-hci-vm network lnet create --subscription $using:subId --resource-group $using:rg --custom-location $customLocationID --location $using:location --name $lnetName --vm-switch-name $switchName --ip-allocation-method "static" --address-prefixes $addressPrefixes --gateway $gateway --dns-servers $dnsServers --vlan $vlanid
}