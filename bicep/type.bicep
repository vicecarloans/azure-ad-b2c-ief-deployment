

@export()
type Tenant = {
  sendgridFromEmail: string
  sendgridTemplateId: string
  name: string
}

@export()
type AzureContainerRegistry = {
  name: string
  subscriptionId: string
  resourceGroup: string
  loginServer: string
}
