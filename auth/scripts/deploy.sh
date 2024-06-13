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

if [[ -z "$TENANT_NAME" ]]; then
    echo "Tenant name is required. Please provide environment variable TENANT_NAME {tenant name without .onmicrosoft.com}"
    exit 1
fi


echo "👨‍💻 Login into Azure AD Tenant: $TENANT_NAME"
az login --service-principal -u $SERVICE_PRINCIPAL_CLIENT_ID -p $SERVICE_PRINCIPAL_CLIENT_SECRET --tenant "$TENANT_NAME.onmicrosoft.com" --allow-no-subscription

CURRENT_FILE_PATH=$(dirname "$0")
TENANT_ID=$(az account show --query id -o tsv)

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