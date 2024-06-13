using 'main.bicep'

param name = 'AzureADB2CDeployment'
param location = 'canadacentral'
param acr = {
  name: 'repository-name'
  subscriptionId: 'azure-subscription-id'
  resourceGroup: 'azure-resource-group-name'
  loginServer: 'repository-name.azurecr.io'
}
param tenant = {
  name: 'your-azure-ad-b2c-tenant-name-without-onmicrosoft'
  sendgridFromEmail: 'sengrid-from-email'
  sendgridTemplateId: 'sendgrid-template-id'
}
param authImage = {
  name: 'image-name'
  tag: 'latest'
}
param keyVault = {
  name: 'vault-name'
}
