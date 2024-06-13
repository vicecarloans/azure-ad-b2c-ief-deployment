#!/bin/bash
set -e

# SendGrid
SENDGRID_TEMPLATE_ID="template-id"
SENDGRID_FROM_EMAIL="from-email"

ROOT_TENANT_NAME="your-root-tenant-name"
ROOT_SUBSCRIPTION="your-root-subscription-id"
CALLBACK_URL="callback-url"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --root-tenant-name) ROOT_TENANT_NAME="$2"; shift ;;
        --root-subscription) ROOT_SUBSCRIPTION="$2"; shift ;;
        # Without .omicrosoft.com
        --tenant-name) TENANT_NAME="$2"; shift ;;
        --callback-url) CALLBACK_URL="$2"; shift ;;
        --sendgrid-template-id) SENDGRID_TEMPLATE_ID="$2"; shift ;;
        --sendgrid-from-email) SENDGRID_FROM_EMAIL="$2"; shift ;;
    esac
    shift
done

# Required environment variables
SENDGRID_SECRET="$SENDGRID_SECRET"
SERVICE_PRINCIPAL_CLIENT_ID="$SERVICE_PRINCIPAL_CLIENT_ID"
SERVICE_PRINCIPAL_CLIENT_SECRET="$SERVICE_PRINCIPAL_CLIENT_SECRET"

# Static Variables
ADMIN_CLIENT_PERMISSIONS=("Directory.ReadWrite.All" "User.ManageIdentities.All" "User.ReadWrite.All" "TrustFrameworkKeySet.ReadWrite.All" "Policy.ReadWrite.TrustFramework" "Policy.ReadWrite.PermissionGrant" "Policy.ReadWrite.ConsentRequest")

MICROSOFT_GRAPH_APP_ID='00000003-0000-0000-c000-000000000000'  # This is a well-known Microsoft Graph application ID.

echo "Setting up azure ad b2c tenant $TENANT_NAME for the first time"
echo "Please make sure you have Global Administrator role. If not, please ask your Azure Instance Admin to run this script."
echo "🛑 This only works in interactive mode. Make sure you have your credentials ready for input for $TENANT_NAME"

az login -t "$TENANT_NAME.onmicrosoft.com" --allow-no-subscription
sleep 1;

TENANT_ID=$(az account show --query id -o tsv)


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

# Create Client Application
echo "Provisioning API Client Application..."
standard_oidc_access_payload="{\"resourceAppId\":\"$MICROSOFT_GRAPH_APP_ID\",\"resourceAccess\":[{\"id\":\"37f7f235-527c-4136-accd-4a02d197296e\",\"type\":\"Scope\"},{\"id\":\"7427e0e9-2fba-42fe-b0c0-848c9e6a8182\",\"type\":\"Scope\"}]}"
api_resource_access_payload="[$standard_oidc_access_payload]"
client_app=$(create_app_if_not_exist "API Client" "--is-fallback-public-client false --enable-access-token-issuance true --sign-in-audience AzureADandPersonalMicrosoftAccount --web-redirect-uris $CALLBACK_URL --required-resource-accesses $api_resource_access_payload" )

# Create Admin Client Application
echo "Provisioning API Admin Client Application..."
api_admin_resource_access_payload="[$standard_oidc_access_payload]"
admin_client_app=$(create_app_if_not_exist "API Admin Client" "--is-fallback-public-client false --enable-access-token-issuance true --sign-in-audience AzureADandPersonalMicrosoftAccount --required-resource-accesses $api_resource_access_payload")

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

echo "Provision Admin API Client Permissions..."
for permission in "${ADMIN_CLIENT_PERMISSIONS[@]}"; do
    add_permission_if_not_exist "$admin_client_app" "$permission"
done
sleep 30
grant_admin_consent $admin_client_app
echo "Provision API Client Permissions..."
grant_admin_consent $client_app

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

generate_policy_key_if_not_exists() {
    local key_name="$1"
    local key_type="$2" # either enc for encryption or sig for signing

    local key_id=$(az rest -m get \
                    -u "https://graph.microsoft.com/beta/trustFramework/keySets/B2C_1A_$key_name/getActiveKey" | jq -r '.kid')

    if [ -z "$key_id" ]; then
        echo "Generate key for keyset $key_name"
        az rest -m post \
                -u "https://graph.microsoft.com/beta/trustFramework/keySets/B2C_1A_$key_name/generateKey" \
                --headers "Content-Type=application/json" \
                -b "{ 'use': '$key_type', 'kty': 'RSA' }"
    else
        echo "$key_name key already exists with kid: $key_id"
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

expose_ief_api() {
    local app_id="$1"
    local scope_id=$(az ad app show --id $app_id --query "api.oauth2PermissionScopes[?value=='user_impersonation'].id" -o tsv)

    if [ -z "$scope_id" ]; then
        echo "Exposing an API for application $app_id"
        payload="{'api': { 'oauth2PermissionScopes': [{'adminConsentDescription': 'Allow the application to access IdentityExperienceFramework on behalf of the signed-in user.', 'adminConsentDisplayName': 'Access IdentityExperienceFramework', 'id': 'a99707a4-827f-4853-b110-164c47262cb4', 'isEnabled': true, 'type': 'User', 'userConsentDescription': 'Allow the application to access IdentityExperienceFramework on your behalf.', 'userConsentDisplayName': 'Access IdentityExperienceFramework', 'value': 'user_impersonation'}]}}"
        az rest -m patch \
            -u "https://graph.microsoft.com/v1.0/applications(appId='$app_id')" \
            --headers "Content-Type=application/json" \
            -b "$payload"
    else
        echo "API already exposed for application $app_id with scope ID: $scope_id"
    fi
}

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

# Generate Identity Experience Framework Application
echo "Generating IdentityExperienceFramework application"
ief_app_resource_access_payload="[$standard_oidc_access_payload]"
ief_app_id=$(create_app_if_not_exist "IdentityExperienceFramework" "--identifier-uris https://$TENANT_NAME.onmicrosoft.com/IdentityExperienceFramework --web-redirect-uris https://$TENANT_NAME.b2clogin.com/$TENANT_NAME.onmicrosoft.com --required-resource-accesses $ief_app_resource_access_payload")

expose_ief_api "$ief_app_id"

sleep 5

grant_admin_consent $ief_app_id

echo "Generating ProxyIdentityExperienceFramework application"

echo $ief_app_id

ief_api_access_id=$(az ad app show --id $ief_app_id --query "api.oauth2PermissionScopes[?value=='user_impersonation'].id" -o tsv)
ief_resource_acccess_payload="{\"resourceAppId\":\"$ief_app_id\",\"resourceAccess\":[{\"id\":\"$ief_api_access_id\",\"type\":\"Scope\"}]}"
graph_resource_access_payload="{\"resourceAppId\":\"$MICROSOFT_GRAPH_APP_ID\",\"resourceAccess\":[{\"id\":\"e1fe6dd8-ba31-4d61-89e7-88639da4683d\",\"type\":\"Scope\"},{\"id\":\"37f7f235-527c-4136-accd-4a02d197296e\",\"type\":\"Scope\"},{\"id\":\"7427e0e9-2fba-42fe-b0c0-848c9e6a8182\",\"type\":\"Scope\"}]}"
proxy_ief_resource_access_payload="[$ief_resource_acccess_payload,$graph_resource_access_payload]"
proxy_ief_app_id=$(create_app_if_not_exist "ProxyIdentityExperienceFramework" "--is-fallback-public-client --public-client-redirect-uris https://login.microsoftonline.com/$TENANT_NAME.onmicrosoft.com --required-resource-accesses $proxy_ief_resource_access_payload")

sleep 5

grant_admin_consent $proxy_ief_app_id
   

setup_ief() {
    # Generate Policy Key Sets
    echo "Generating policy key sets TokenSigningKeyContainer."
    create_policy_key_if_not_exists "TokenSigningKeyContainer"
    generate_policy_key_if_not_exists "TokenSigningKeyContainer" "sig"
    echo "Generating policy key sets TokenEncryptionKeyContainer."
    create_policy_key_if_not_exists "TokenEncryptionKeyContainer"
    generate_policy_key_if_not_exists "TokenEncryptionKeyContainer" "enc"
    echo "Generating policy key sets for SendGrid."
    create_policy_key_if_not_exists "SendGridSecret"
    upload_policy_key_if_not_exists "SendGridSecret" "$SENDGRID_SECRET"

    # Generate Identity Experience Framework Policy
    CURRENT_FILE_PATH=$(dirname "$0")

    # Trust Framework Base
    trust_framework_base_temp=$(mktemp)
    xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
        -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_TrustFrameworkBase" \
        -u "//cpim:Item[@Key='METADATA']" -v "https://login.microsoftonline.com/$TENANT_NAME.onmicrosoft.com/.well-known/openid-configuration" \
        -u "//cpim:Item[@Key='authorization_endpoint']" -v "https://login.microsoftonline.com/$TENANT_NAME.onmicrosoft.com/oauth2/token" \
        "$CURRENT_FILE_PATH/../base-policy/TrustFrameworkBase.xml" >> $trust_framework_base_temp
    upload_policy "B2C_1A_TrustFrameworkBase" "$(cat $trust_framework_base_temp)"

    sleep 5

    # Trust Framework Localization
    trust_framework_localization_temp=$(mktemp)
    xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
        -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_TrustFrameworkLocalization" \
        -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        "$CURRENT_FILE_PATH/../base-policy/TrustFrameworkLocalization.xml" >> $trust_framework_localization_temp
    
    upload_policy "B2C_1A_TrustFrameworkLocalization" "$(cat $trust_framework_localization_temp)"


    sleep 5

    # Trust Framework Extensions
    trust_framework_extensions_temp=$(mktemp)
    xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
        -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_TrustFrameworkExtensions" \
        -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        -u "//cpim:Item[@Key='client_id']" -v "$proxy_ief_app_id" \
        -u "//cpim:InputClaim[@ClaimTypeReferenceId='client_id']/@DefaultValue" -v "$proxy_ief_app_id" \
        -u "//cpim:Item[@Key='IdTokenAudience']" -v "$ief_app_id" \
        -u "//cpim:InputClaim[@ClaimTypeReferenceId='resource_id']/@DefaultValue" -v "$ief_app_id" \
        "$CURRENT_FILE_PATH/../base-policy/TrustFrameworkExtensions.xml" >> $trust_framework_extensions_temp

    upload_policy "B2C_1A_TrustFrameworkExtensions" "$(cat $trust_framework_extensions_temp)"
    
    sleep 5

    # Sign Up or Sign In
    sign_up_or_sign_in_temp=$(mktemp)
    xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
        -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_signup_signin" \
        -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        "$CURRENT_FILE_PATH/../base-policy/SignUpOrSignin.xml" >> $sign_up_or_sign_in_temp
    
    upload_policy "B2C_1A_signup_signin" "$(cat $sign_up_or_sign_in_temp)"

    sleep 5
    # Profile Edit
    profile_edit_temp=$(mktemp)
    xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
        -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_ProfileEdit" \
        -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        "$CURRENT_FILE_PATH/../base-policy/ProfileEdit.xml" >> $profile_edit_temp
    
    upload_policy "B2C_1A_ProfileEdit" "$(cat $profile_edit_temp)"

    sleep 5
    # Password Reset
    password_reset_temp=$(mktemp)
    xmlstarlet ed -N cpim="http://schemas.microsoft.com/online/cpim/schemas/2013/06" \
        -u "//cpim:TrustFrameworkPolicy/@TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        -u "//cpim:TrustFrameworkPolicy/@PublicPolicyUri" -v "http://$TENANT_NAME.onmicrosoft.com/B2C_1A_PasswordReset" \
        -u "//cpim:TenantId" -v "$TENANT_NAME.onmicrosoft.com" \
        "$CURRENT_FILE_PATH/../base-policy/PasswordReset.xml" >> $password_reset_temp
    
    upload_policy "B2C_1A_PasswordReset" "$(cat $password_reset_temp)"
}

echo "👨‍💻 Login into Azure AD Tenant: $TENANT_NAME"
az login --service-principal -u $SERVICE_PRINCIPAL_CLIENT_ID -p $SERVICE_PRINCIPAL_CLIENT_SECRET --tenant "$TENANT_NAME.onmicrosoft.com" --allow-no-subscription


echo "🚧 Setup Identity Experience Framework..."
setup_ief

echo "🚀🚀🚀 Azure AD B2C tenant $TENANT_NAME setup completed successfully 🚀🚀🚀"

