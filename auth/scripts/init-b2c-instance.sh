#!/bin/bash
set -e

AZURE_APP_NAME="AzureADScripts"
CURRENT_SUBSCRIPTION="Enter your subscription ID here"
RESOURCE_GROUP="Enter your resource group here"
ROOT_TENANT_NAME="Enter your root tenant name here"
# Make sure Vault exists
VAULT_NAME="Enter your vault name here"

AZURE_AD_B2C_TENANT_NAME="Enter your B2C tenant name here without .onmicrosoft.com"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --app-name) AZURE_APP_NAME="$2"; shift ;;
        --subscription) CURRENT_SUBSCRIPTION="$2"; shift ;;
        --resource-group) RESOURCE_GROUP="$2"; shift ;;
        --root-tenant-name) ROOT_TENANT_NAME="$2"; shift ;;
        --vault-name) VAULT_NAME="$2"; shift ;;
        # Without .onmicrosoft.com
        --tenant-name) AZURE_AD_B2C_TENANT_NAME="$2"; shift ;;
    esac
    shift
done

az login -t $ROOT_TENANT_NAME

az account set --subscription $CURRENT_SUBSCRIPTION

app_id=$(az ad app list --display-name "$AZURE_APP_NAME" --query "[].appId" -o tsv)



if [[ -z "$app_id" ]]; then
    echo "Creating Azure AD app..."
    app_id=$(az ad app create --display-name "$AZURE_APP_NAME" --sign-in-audience AzureADMultipleOrgs --query "appId" -o tsv)
    echo "Created Azure AD app with ID: $app_id"
    service_principal=$(az ad sp create-for-rbac --name "$AZURE_APP_NAME" --role Contributor --scope "/subscriptions/$CURRENT_SUBSCRIPTION")
    my_id=$(az ad signed-in-user show --query id -o tsv)
    echo "Assigning Key Vault access to me - $my_id"
    az role assignment create --assignee "$my_id" --role "Key Vault Administrator" --scope "/subscriptions/$CURRENT_SUBSCRIPTION"
    echo "Wait for propagation..."
    sleep 30
    service_principal_client_id=$(echo $service_principal | jq -r '.appId')
    az keyvault secret set --name "ServicePrincipalClientId" --vault-name "$VAULT_NAME" --value "$service_principal_client_id" --output none
    service_principal_client_secret=$(echo $service_principal | jq -r '.password')
    az keyvault secret set --name "ServicePrincipalClientSecret" --vault-name "$VAULT_NAME" --value "$service_principal_client_secret" --output none
    
    # Permissions
    echo "Setting up permissions for App"
    MICROSOFT_GRAPH_APP_ID='00000003-0000-0000-c000-000000000000'  # This is a well-known Microsoft Graph application ID.
    USER_READ_WRITE_ALL_ID='741f803b-c850-494e-b5df-cde7c675a1ca'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$USER_READ_WRITE_ALL_ID=Role"

    APPLICATION_READ_WRITE_ALL_ID='1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$APPLICATION_READ_WRITE_ALL_ID=Role"

    DIRECTORY_READ_WRITE_ALL_ID='19dbc75e-c2e2-444c-a770-ec69d8559fc7'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$DIRECTORY_READ_WRITE_ALL_ID=Role"

    POLICY_READ_WRITE_CONSENT_REQUEST_ID='999f8c63-0a38-4f1b-91fd-ed1947bdd1a9'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$POLICY_READ_WRITE_CONSENT_REQUEST_ID=Role"

    POLICY_READ_WRITE_PERMISSION_GRANT_ID='a402ca1c-2696-4531-972d-6e5ee4aa11ea'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$POLICY_READ_WRITE_PERMISSION_GRANT_ID=Role"

    POLICY_READ_WRITE_TRUST_FRAMEWORK_ID='79a677f7-b79d-40d0-a36a-3e6f8688dd7a'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$POLICY_READ_WRITE_TRUST_FRAMEWORK_ID=Role"

    TRUST_FRAMEWORK_KEY_SET_READ_WRITE_ALL_ID='4a771c9a-1cf2-4609-b88e-3d3e02d539cd'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$TRUST_FRAMEWORK_KEY_SET_READ_WRITE_ALL_ID=Role"
    
    USER_MANAGE_IDENTITIES_ALL_ID='c529cfca-c91b-489c-af2b-d92990b66ce6'
    az ad app permission add --id $app_id --api "$MICROSOFT_GRAPH_APP_ID" --api-permissions "$USER_MANAGE_IDENTITIES_ALL_ID=Role"

    echo "🙏 Please give consent to this. If this does not work, please check if you have at least Global Administrator access"

    az ad app permission admin-consent --id $app_id

    echo "Script executed successfully! Your App is ready 🚀🚀🚀"
else
    echo "Azure AD app already exists with ID: $app_id. Nothing to do..."
fi

echo "Assigning Contributor to Service Principal"
az role assignment create --assignee "$app_id" --role "Contributor" --scope "/subscriptions/$CURRENT_SUBSCRIPTION"

create_tenant_if_not_exist() {
    tenant_id=$(az rest -m get \
        --url "https://management.azure.com/subscriptions/$CURRENT_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.AzureActiveDirectory/b2cDirectories/$AZURE_AD_B2C_TENANT_NAME.onmicrosoft.com?api-version=2023-05-17-preview" \
        -o json | jq -c ".id"
    )

    if [[ -z "$tenant_id" ]]; then
        echo "🔨 🔨 🔨 Creating B2C Tenant $AZURE_AD_B2C_TENANT_NAME..."
        payload="{'location':'United States','sku':{'name':'PremiumP1','tier':'A0'},'properties':{'createTenantProperties':{'countryCode':'CA','displayName':'$AZURE_AD_B2C_TENANT_NAME'}}}"

        az rest -m put \
            --url "https://management.azure.com/subscriptions/$CURRENT_SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.AzureActiveDirectory/b2cDirectories/$AZURE_AD_B2C_TENANT_NAME.onmicrosoft.com?api-version=2023-05-17-preview" \
            --headers "Content-Type=application/json" \
            -b "$payload" \
            --verbose

        echo "Waiting for B2C Tenant to be created..."
        sleep 60
        
        echo "🏠 Created B2C Tenant $AZURE_AD_B2C_TENANT_NAME"
    else
        echo "🏠 B2C Tenant $AZURE_AD_B2C_TENANT_NAME already exists with ID: $tenant_id. Nothing to do..."
    fi
}

create_tenant_if_not_exist


echo "💻 Setup Login for Tenant $AZURE_AD_B2C_TENANT_NAME..."

az login -t "$AZURE_AD_B2C_TENANT_NAME.onmicrosoft.com" --allow-no-subscription

TENANT_ID=$(az account show --query tenantId -o tsv)

login_service_principal=$(az ad sp list --filter "appId eq '$app_id'" --query '[].id' -o tsv)

if [[ -z "$login_service_principal" ]]; then
    az ad sp create --id $app_id
else
    echo "Login service principal already exists with ID: $login_service_principal"
fi

echo "🙏 Please give consent to this. If this does not work, please check if you have at least Global Administrator access"
sensible-browser "https://login.microsoftonline.com/$TENANT_ID/adminConsent?client_id=$app_id&redirect_uri=https://portal.azure.com/TokenAuthorize"

