
param principalId string
param acrName string
param assignments { role: string, condition: string? }[] = []

var roleIds = [for assignment in assignments: resourceId('Microsoft.Authorization/roleDefinitions', assignment.role)]

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = { name: acrName }

resource acrRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
for i in range(0, length(assignments)): {
  name: guid('${principalId}_${assignments[i].role}')
  properties: {
    #disable-next-line use-resource-id-functions
    roleDefinitionId: roleIds[i]
    principalId: principalId
    principalType: 'ServicePrincipal'
    condition: contains(assignments[i], 'condition') ? assignments[i].condition : null
    conditionVersion: contains(assignments[i], 'condition') ? '2.0' : null
  }
  scope: containerRegistry
}
]
