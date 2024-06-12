param location string = resourceGroup().location
param tags { *: string } = {}
param name string = '${resourceGroup()}UAI'

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

output principalId string = userAssignedIdentity.properties.principalId
output id string = userAssignedIdentity.id
