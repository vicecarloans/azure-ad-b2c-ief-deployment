
import {Tenant,  AzureContainerRegistry } from '../type.bicep'


param location string = resourceGroup().location
param tags { *: string } = {}
@description('Set a different script version to trigger deployment of Azure AD B2C Resources')
param scriptVersion string = utcNow()
param identityId string

param jobName string
param resourceGroupName string = resourceGroup().name

param image { name: string, tag: string }
param acr AzureContainerRegistry
param tenant Tenant
param name string

resource adb2cDeploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${name}-ADB2C-DeploymentScript'
  location: location
  kind: 'AzureCLI'
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    azCliVersion: '2.59.0'
    scriptContent: '''
    #!/bin/bash

    az login --identity 
    
    az containerapp job start --name "$JOB_NAME" \
                              --subscription "$ROOT_SUBSCRIPTION" \
                              --resource-group "$RESOURCE_GROUP" \
                              --image "$CONTAINER_IMAGE" \
                              --command "./scripts/deploy.sh" \
                              --env-vars "SERVICE_PRINCIPAL_CLIENT_ID=secretref:service-principal-client-id" \
                              "SERVICE_PRINCIPAL_CLIENT_SECRET=secretref:service-principal-client-secret" \
                              "TENANT_NAME=$TENANT_NAME" \
                              "SENDGRID_TEMPLATE_ID=$SENDGRID_TEMPLATE_ID" \
                              "SENDGRID_FROM_EMAIL=$SENDGRID_FROM_EMAIL" \
                              "SENDGRID_SECRET=secretref:sendgrid-secret"
    '''
    environmentVariables: [
      {
        name: 'TENANT_NAME'
        value: tenant.name
      }
      {
        name: 'SENDGRID_TEMPLATE_ID'
        value: tenant.sendgridTemplateId
      }
      {
        name: 'SENDGRID_FROM_EMAIL'
        value: tenant.sendgridFromEmail
      }
      {
        name: 'JOB_NAME'
        value: jobName
      }
      {
        name: 'RESOURCE_GROUP'
        value: resourceGroupName
      }
      {
        // This is necessary otherwise containerapp job start won't override startup command
        name: 'CONTAINER_IMAGE'
        value: '${acr.loginServer}/${image.name}:${image.tag}'
      }
    ]
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    timeout: 'PT1H'
    forceUpdateTag: scriptVersion
  }
}

