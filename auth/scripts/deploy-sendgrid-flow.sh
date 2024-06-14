#!/bin/bash
set -e

# Required environment variables
SERVICE_PRINCIPAL_CLIENT_ID="$SERVICE_PRINCIPAL_CLIENT_ID"
SERVICE_PRINCIPAL_CLIENT_SECRET="$SERVICE_PRINCIPAL_CLIENT_SECRET"
TENANT_NAME="$TENANT_NAME"

# Sendgrid
DEFAULT_SENDGRID_TEMPLATE_ID="template-id"
SENDGRID_TEMPLATE_ID="${SENDGRID_TEMPLATE_ID:-$DEFAULT_SENDGRID_TEMPLATE_ID}"
DEFAULT_FROM_EMAIL="from-email"
SENDGRID_FROM_EMAIL="${SENDGRID_FROM_EMAIL:-$DEFAULT_FROM_EMAIL}"
SENDGRID_SECRET="$SENDGRID_SECRET"

CALLBACK_URL="${CALLBACK_URL:-https://jwt.ms}"

if [[ -z "$TENANT_NAME" ]]; then
    echo "Tenant name is required. Please provide environment variable TENANT_NAME {tenant name without .onmicrosoft.com}"
    exit 1
fi


echo "👨‍💻 Login into Azure AD Tenant: $TENANT_NAME"
az login --tenant "$TENANT_NAME.onmicrosoft.com" --allow-no-subscription

CURRENT_FILE_PATH=$(dirname "$0")
TENANT_ID=$(az account show --query id -o tsv)


# Static Variables
MICROSOFT_GRAPH_APP_ID='00000003-0000-0000-c000-000000000000'  # This is a well-known Microsoft Graph application ID.

check_app_exist() {
    local app_name="$1"
    echo $(az ad app list --display-name "$app_name" --query "[].appId" -o tsv)
}

create_app_if_not_exist() {
    local app_name="$1"
    local app_id=$(check_app_exist "$app_name")
    local flags=$2
    
    if [ -z "$app_id" ]; then
        app_id=$(az ad app create --display-name "$app_name" $flags --query appId -o tsv)
    fi

    echo $app_id
}

grant_admin_consent() {
    local app_id="$1"

    if [ -z "$app_id" ]; then
        echo "Application ID is required to grant admin consent"
        exit 1
    fi
    
    echo "Granting admin consent to application $app_id"

    az ad app permission admin-consent --id $app_id
}

# Permission
add_permission_if_not_exist() {
    local app_id="$1"
    local permission="$2"
    local resource_app_id="${3:-$MICROSOFT_GRAPH_APP_ID}" 
    # Role for Application level and Scope for Delegated permissions
    local level="${4:-"Role"}"   
    
    if [ -z "$app_id" ]; then
        echo "Application ID is required to add permissions"
        exit 1
    fi
    # Get current permissions
    current_permissions=$(az ad app show --id $app_id --query "requiredResourceAccess[].resourceAccess[].id" -o tsv)

    echo "Querying permission ID for: $permission"

    # Query for the permission ID based on the permission name
    permission_data=$(az ad sp list --filter "appId eq '$resource_app_id'" --query "[].appRoles[?value=='$permission'].{id:id}" -o json)
    permission_id=$(echo $permission_data | jq -r '[.[][0].id]' | jq -r '.[0]')

    if [[ "$permission_id" != "null" && ! $current_permissions =~ $permission_id ]]; then
        echo "Adding permission '$permission' (ID: $permission_id) to application '$app_id'"
        az ad app permission add --id $app_id --api $resource_app_id --api-permissions "$permission_id=$level" --output none
    else
        echo "Permission ID for '$permission' not found or already exists in application '$app_id'"
    fi
    
}

# Create Client Application
echo "Provisioning API Client Application..."
standard_oidc_access_payload="{\"resourceAppId\":\"$MICROSOFT_GRAPH_APP_ID\",\"resourceAccess\":[{\"id\":\"37f7f235-527c-4136-accd-4a02d197296e\",\"type\":\"Scope\"},{\"id\":\"7427e0e9-2fba-42fe-b0c0-848c9e6a8182\",\"type\":\"Scope\"}]}"
api_resource_access_payload="[$standard_oidc_access_payload]"
client_app=$(create_app_if_not_exist "API Client" "--is-fallback-public-client false --enable-access-token-issuance true --sign-in-audience AzureADandPersonalMicrosoftAccount --web-redirect-uris $CALLBACK_URL --required-resource-accesses $api_resource_access_payload" )

echo "Provision API Client Permissions..."
grant_admin_consent $client_app

echo "Generating policy key sets for SendGrid."

create_policy_key_if_not_exists() {
    local key_name="$1"

    local key_id=$(az rest -m get \
                    -u "https://graph.microsoft.com/beta/trustFramework/keySets/B2C_1A_$key_name" | jq -r '.id')

    if [ -z "$key_id" ]; then
        echo "Creating policy key $key_name"
        az rest -m post \
                -u "https://graph.microsoft.com/beta/trustFramework/keySets" \
                --headers "Content-Type=application/json" \
                -b "{'id': '$key_name'}"
    else
        echo "$key_name key already exists with ID: $key_id"
    fi
}

upload_policy_key_if_not_exists() {
    local key_name="$1"
    local key_value="$2"
    local key_id=$(az rest -m get \
                            -u "https://graph.microsoft.com/beta/trustFramework/keySets/B2C_1A_$key_name/getActiveKey" | jq -r '.kid')

    if [ -z "$key_id" ]; then
        echo "Upload key for keyset $key_name"
        az rest -m post \
                -u "https://graph.microsoft.com/beta/trustFramework/keySets/B2C_1A_$key_name/uploadSecret" \
                --headers "Content-Type=application/json" \
                -b "{ 'use': 'sig', 'k': '$key_value' }"
    else
        echo "$key_name key already exists with kid: $key_id"
    fi
}

echo "Login using Service Principal..."

az login --service-principal -u $SERVICE_PRINCIPAL_CLIENT_ID -p $SERVICE_PRINCIPAL_CLIENT_SECRET --tenant "$TENANT_NAME.onmicrosoft.com" --allow-no-subscription

create_policy_key_if_not_exists "SendGridSecret"
upload_policy_key_if_not_exists "SendGridSecret" "$SENDGRID_SECRET"

upload_policy () {
    local policy_name="$1"
    local policy_file_content="$2"

    echo "Upload Policy: $policy_name"
    
    curl -X PUT "https://graph.microsoft.com/beta/trustFramework/policies/$policy_name/\$value" \
        --retry 5 \
        --retry-max-time 120 \
        -H "Authorization: Bearer $(az account get-access-token --resource-type ms-graph --query accessToken -o tsv)" \
        -H "Content-Type: application/xml" \
        -H "charset: utf-8" \
        -d "$policy_file_content"
}

# Custom Policy
# DisplayControl_TrustFrameworkExtensions
display_control_trust_framework_extensions=$(mktemp)
xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
    -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
    -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_DisplayControl_sendgrid_Extensions" \
    -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
    -u "//cpim:InputParameter[@Id='template_id']/@Value" -v "$SENDGRID_TEMPLATE_ID" \
    -u "//cpim:InputParameter[@Id='from.email']/@Value" -v "$SENDGRID_FROM_EMAIL" \
    "$CURRENT_FILE_PATH/../policy/DisplayControl_TrustFrameworkExtensions.xml" >> $display_control_trust_framework_extensions

upload_policy "B2C_1A_DisplayControl_sendgrid_Extensions" "$(cat $display_control_trust_framework_extensions)"


sleep 5
# DisplayControl_TrustFrameworkExtensions
display_control_sendgrid_signin=$(mktemp)
xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
    -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
    -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_DisplayControl_sendgrid_Signin" \
    -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
    "$CURRENT_FILE_PATH/../policy/DisplayControl_SignUpOrSignin.xml" >> $display_control_sendgrid_signin

upload_policy "B2C_1A_DisplayControl_sendgrid_Signin" "$(cat $display_control_sendgrid_signin)"

# DisplayControl_TrustFrameworkExtensions
display_control_sendgrid_passwordreset=$(mktemp)
xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
    -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
    -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_DisplayControl_sendgrid_PasswordReset" \
    -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
    "$CURRENT_FILE_PATH/../policy/DisplayControl_PasswordReset.xml" >> $display_control_sendgrid_passwordreset

upload_policy "B2C_1A_DisplayControl_sendgrid_PasswordReset" "$(cat $display_control_sendgrid_passwordreset)"

echo "🚀 Script executed successfully! Your Tenant $TENANT_NAME assets and policies are up to date! 🚀"