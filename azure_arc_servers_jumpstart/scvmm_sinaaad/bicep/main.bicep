@description('Azure service principal client id')
param spnClientId string

@description('Azure service principal client secret')
@secure()
param spnClientSecret string

@description('Azure AD tenant id for your service principal')
param spnTenantId string

@description('Username for Windows account')
param windowsAdminUsername string

@description('Password for Windows account. Password must have 3 of the following: 1 lower case character, 1 upper case character, 1 number, and 1 special character. The value must be between 12 and 123 characters long')
@minLength(12)
@maxLength(123)
@secure()
param windowsAdminPassword string

@description('Target GitHub account')
param githubAccount string = 'lanicolas'

@description('Target GitHub branch')
param githubBranch string = 'scvmm'

@description('Choice to deploy Bastion to connect to the client VM')
param deployBastion bool = true

var templateBaseUrl = 'https://raw.githubusercontent.com/${githubAccount}/azure_arc/${githubBranch}/azure_arc_servers_jumpstart/scvmm_sinaaad/'

var location = resourceGroup().location


module clientVmDeployment 'clientVm/clientVm.bicep' = {
  name: 'clientVmDeployment'
  params: {
    windowsAdminUsername: windowsAdminUsername
    windowsAdminPassword: windowsAdminPassword
    spnClientId: spnClientId
    spnClientSecret: spnClientSecret
    spnTenantId: spnTenantId
    templateBaseUrl: templateBaseUrl
    subnetId: mgmtArtifactsAndPolicyDeployment.outputs.subnetId
    deployBastion: deployBastion
    location: location
  }
}

module mgmtArtifactsAndPolicyDeployment 'mgmt/mgmtArtifacts.bicep' = {
  name: 'mgmtArtifactsAndPolicyDeployment'
  params: {    deployBastion: deployBastion
    location: location
  }
}

output clientVmLogonUserName string = windowsAdminUsername
