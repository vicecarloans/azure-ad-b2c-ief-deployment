param principalId string
param jobName string
param assignments { role: string, condition: string? }[] = []

var roleIds = [for assignment in assignments: resourceId('Microsoft.Authorization/roleDefinitions', assignment.role)]

resource job 'Microsoft.App/jobs@2023-05-01' existing = { name: jobName }

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for i in range(0, length(assignments)): {
    name: guid('${principalId}_${assignments[i].role}_${jobName}')
    properties: {
      #disable-next-line use-resource-id-functions
      roleDefinitionId: roleIds[i]
      principalId: principalId
      principalType: 'ServicePrincipal'
      condition: contains(assignments[i], 'condition') ? assignments[i].condition : null
      conditionVersion: contains(assignments[i], 'condition') ? '2.0' : null
    }
    scope: job
  }
]
