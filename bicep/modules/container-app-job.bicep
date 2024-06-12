type Resources = { cpu: string, memory: string }

param location string = resourceGroup().location
param tags { *: string } = {}
param environmentId string
param identityId string
param acr {
  name: string
  subscriptionId: string
  resourceGroup: string
  loginServer: string
}
param name string
param parallelism int = 1
param resources Resources
param image { name: string, tag: string }
param command string[]
param keyVaultName string
param extraEnvVars { name: string, value: string }[] = []

var secrets = map(
  [
    { name: 'service-principal-client-id', secretName: 'ServicePrincipalClientId' }
    { name: 'service-principal-client-secret', secretName: 'ServicePrincipalClientSecret' }
  ],
  secret => { name: secret.name, secretName: secret.secretName, vault: keyVaultName }
)

var jobName = '${substring(name, 0, min(10, length(name)))}-${uniqueString(name)}'

var vaultSuffix = environment().suffixes.keyvaultDns

resource job 'Microsoft.App/jobs@2023-05-01' = {
  name: jobName
  location: location
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identityId}': {} } }
  tags: union(tags, { name: name })
  properties: {
    environmentId: environmentId
    configuration: {
      secrets: [
        for secret in secrets: {
          identity: identityId
          keyVaultUrl: 'https://${secret.vault}${vaultSuffix}/secrets/${secret.secretName}'
          name: secret.name
        }
      ]
      triggerType: 'Manual'
      registries: [{ server: acr.loginServer, identity: identityId }]
      manualTriggerConfig: { parallelism: parallelism, replicaCompletionCount: 1 }
      replicaTimeout: 1800
      replicaRetryLimit: 3
    }
    template: {
      containers: [
        {
          name: name
          image: '${acr.loginServer}/${image.name}:${image.tag}'
          resources: resources
          command: command
          env: union(
            [
              { name: 'SERVICE_PRINCIPAL_CLIENT_ID', secretRef: 'service-principal-client-id' }
              { name: 'SERVICE_PRINCIPAL_CLIENT_SECRET', secretRef: 'service-principal-client-secret' }
            ],
            extraEnvVars
          )
        }
      ]
    }
  }
}

output jobName string = jobName
