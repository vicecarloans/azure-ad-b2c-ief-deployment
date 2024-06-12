param location string = resourceGroup().location
param tags { *: string } = {}
param name string = '${resourceGroup().name}CAE'

resource environment 'Microsoft.App/connectedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {}
}

output environmentId string = environment.id
