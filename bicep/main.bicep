import { AzureContainerRegistry, Tenant } from './type.bicep'
param location string = resourceGroup().location

param tags { *: string } = {}


param acr AzureContainerRegistry

param authImage { name: string, tag: string }

param keyVault { name: string, subscriptionId: string, resourceGroup: string }

@description('Environment name')
param name string

param tenant Tenant

var extendedTags = union(tags, { environment: name })


module KeyVaultSecretsUserRole './modules/built-in-role.bicep' = {
  name: 'KeyVaultSecretsUser'
  params: { roleName: 'Key Vault Secrets User' }
}


module azureADB2CDeploymentJobIdentity './modules/user-assigned-identity.bicep' = {
  name: '${name}AzureADB2CScriptIdentity'
  params: { location: location, name: '${name}AzureADB2CScriptGlobalIdentity', tags: extendedTags }
}

module azureADB2CDeploymentJobAppReaderRoleAssignment './modules/keyvault-role-assignments.bicep' = {
  name: '${name}AzureADB2CJobAppKeyVaultReaderRA'
  params: {
    principalId: azureADB2CDeploymentJobIdentity.outputs.principalId
    keyVaultName: keyVault.name
    assignments: [{ role: KeyVaultSecretsUserRole.outputs.roleId }]
  }
}

module AcrPullRole './modules/built-in-role.bicep' = { name: 'AcrPullRole', params: { roleName: 'AcrPull' } }


module azureADB2CDeploymentJobContainerACRPull './modules/acr-role-assignments.bicep' = {
  name: '${name}AzureADB2CJobContainerACRPullRA'
  params: {
    principalId: azureADB2CDeploymentJobIdentity.outputs.principalId
    acrName: acr.name
    assignments: [{ role: AcrPullRole.outputs.roleId }]
  }
  scope: resourceGroup(acr.subscriptionId, acr.resourceGroup)
}


module containerAppsEnvironment './modules/container-app-environment.bicep' = {
  name: '${name}CAE'
  params: {
    location: location
    name: '${name}CAE'
    tags: tags
  }
}

module azureADB2CDeploymentJob './modules/container-app-job.bicep' = {
  name: '${name}AzureADB2CDeploymentJob'
  params: {
    name: 'azure-ad-b2c-deployment-job'
    tags: tags
    location: location
    keyVaultName: keyVault.name
    acr: acr
    command: []
    environmentId: containerAppsEnvironment.outputs.environmentId
    identityId: azureADB2CDeploymentJobIdentity.outputs.id
    image: { name: authImage.name, tag: authImage.tag }
    resources: { cpu: '1.0', memory: '2.0Gi' }
  }
  dependsOn: [azureADB2CDeploymentJobAppReaderRoleAssignment]
}

module azureADB2CDeploymentJobTriggerIdentity './modules/user-assigned-identity.bicep' = {
  name: '${name}AzureADB2CDeploymentJobTriggerIdentity'
  params: { location: location, name: '${name}AzureADB2CDeploymentJobTriggerIdentity', tags: extendedTags }
}

module contributorRole './modules/built-in-role.bicep' = {
  name: 'ContributorRole'
  params: { roleName: 'Contributor' }
}

module azureAdB2CDeploymentJobTriggerAssignment './modules/job-role-assignments.bicep' = {
  name: '${name}DeploymentJobTriggerAssignment'
  params: {
    jobName: azureADB2CDeploymentJob.outputs.jobName
    principalId: azureADB2CDeploymentJobTriggerIdentity.outputs.principalId
    assignments: [{ role: contributorRole.outputs.roleId }]
  }
  dependsOn: [azureADB2CDeploymentJob, azureADB2CDeploymentJobTriggerIdentity]
}

module azureADB2CDeployment './modules/azure-ad-b2c-deployment-job-trigger.bicep' = {
  name: '${name}AzureADB2C'
  params: {
    location: location
    tags: extendedTags
    jobName: azureADB2CDeploymentJob.outputs.jobName
    tenant: tenant
    resourceGroupName: resourceGroup().name
    identityId: azureADB2CDeploymentJobTriggerIdentity.outputs.id
    image: { name: authImage.name, tag: authImage.tag }
    acr: acr
    name: '${name}AzureADB2CDeploymentScript'
  }
  dependsOn: [azureADB2CDeploymentJob, azureADB2CDeploymentJobTriggerIdentity, azureAdB2CDeploymentJobTriggerAssignment]
}
