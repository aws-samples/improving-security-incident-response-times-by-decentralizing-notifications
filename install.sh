#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Script to install the CloudFormation templates relating to the Service Catalog product
# for subscribing to Security Hub notifications.

set -eu

function get_stack_output() {
  local stack="$1"
  local output="$2"

  value=$(aws --output text cloudformation describe-stacks --stack-name $stack --query "Stacks[].Outputs[?OutputKey=='"$output"'].OutputValue[]")

  if [ -z "$value" ]; then
    >&2 echo "Could not get the Output $output from stack $stack"
    return 1
  fi
  echo $value
}

function get_existing_stack_value_or_default(){
  local stack="$1"
  local parameter="$2"
  local default="$3"
  value=$( aws --output text cloudformation describe-stacks --stack-name $stack --query "Stacks[].Parameters[?ParameterKey==\`$parameter\`]".ParameterValue 2>/dev/null )
  if [ -z "$value" ]; then
    echo $default
  else
    echo $value
  fi
}

sc_stack_name="SecurityNotifications-Service-Catalog"
bucket_stack_name="SecurityNotifications-SC-Bucket"
sc_bucket_template_filename="02_Service_Catalog/01_Bucket/SecurityHub_notifications_SC-Bucket.yaml"
sc_product_template_filename="02_Service_Catalog/02_ServiceCatalog_Product/SecurityHub-Notifications.yaml"
sc_product_temporary_filename="/tmp/SecurityHub-Notifications.yaml"
sc_portfolio_template_filename="02_Service_Catalog/03_ServiceCatalog_Portfolio/SecurityHub_notifications_ServiceCatalog_Portfolio.yaml"


# Ask whether to use the Lambda or non-Lambda version. See README for more information.
use_lambda="Yes"
read -p "Should the notification template/product use Lambda (as opposed to the non-Lambda version)? Yes/No [$use_lambda]: " user_input
test ! -z "$user_input" && use_lambda="$user_input"
# Exit if use_lambda is not set to Yes or No:
if [[ "$use_lambda" != "Yes" && "$use_lambda" != "No" ]]; then
  echo "Invalid input, expecting Yes or No"
  exit 1
fi

if [[ "$use_lambda" == "Yes" ]]; then
  timezone=UTC
  read -p "Enter a zoneinfo style timezone, for example Australia/Melbourne [$timezone]: " user_input
  test ! -z "$user_input" && timezone="$user_input"
  # Check if timezone is valid
  if python3 -c "import zoneinfo; print(zoneinfo.available_timezones())" | grep -qv "'$timezone'"; then
    echo "Invalid timezone. Expected one of:"
    python3 -c "import zoneinfo; import pprint; pprint.pprint(zoneinfo.available_timezones())"
    exit 1
  fi
  timezone=$user_input
fi

# Get company/org name
provider_name=$(get_existing_stack_value_or_default $sc_stack_name "ProviderName" "Security")
read -p "Enter a short organization/company/team name to use as the Service Catalog provider name, no spaces [$provider_name]: " user_input
test ! -z "$user_input" && provider_name="$user_input"

# Get service catalog product version
sc_product_version=$(get_existing_stack_value_or_default $sc_stack_name "ProductVersion" "v1")
read -p "Enter the product version with no spaces (increment this if you many any updates or changes to the `basename $sc_product_template_filename` template) [$sc_product_version]: " user_input
test ! -z "$user_input" && sc_product_version="$user_input"

# Check if IAM Launch role StackSet was created.
sc_launch_role=$(get_existing_stack_value_or_default $sc_stack_name "DeployedIAMRoleStackSet" "No")
read -p "If you deployed the IAM Role StackSet, enter Yes here to use a launch role [$sc_launch_role]: " user_input
test ! -z "$user_input" && sc_launch_role="$user_input"
if [[ "$sc_launch_role" != "Yes" && "$sc_launch_role" != "No" ]]; then
  echo "Invalid input, expecting Yes or No"
  exit 1
fi

# Principal type
sc_principal_type=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalType" "IAM_Identity_Center_Permission_Set")
read -p "Type of principal that will use the product, IAM_Identity_Center_Permission_Set or IAM_role_name [$sc_principal_type]: " user_input
test ! -z "$user_input" && sc_principal_type="$user_input"

iam_identity_center_subdomain="unset"
# If the principal type is IAM Identity Center, we need the IAM Identity Center home region & URL:
if [[ "$sc_principal_type" == "IAM_Identity_Center_Permission_Set" ]]; then

  if [[ "$use_lambda" == "Yes" ]]; then
    # Get IAM Identity Center subdomain:
    read -p "Enter the subdmain of your IAM Identity Center URL. For example, if your URL looks like this https://d-abcd1234.awsapps.com/start/#/ , then enter d-abcd1234  [unset]: " user_input
    test ! -z "$user_input" && iam_identity_center_subdomain="$user_input"
  fi

  # Get IAM Identity Center region:
  sc_iam_identity_center_region=$(get_existing_stack_value_or_default $sc_stack_name "IAMIdentityCenterRegion" "$AWS_DEFAULT_REGION")
  read -p "IAM Identity Center home region [$sc_iam_identity_center_region]: " user_input
  test ! -z "$user_input" && sc_iam_identity_center_region="$user_input"

fi

# Principal name 01
sc_principal_name_01=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalName01" "SubscribeToSecurityNotifications")
read -p "IAM role name or permission set that can access the Service Catalog product [$sc_principal_name_01]: " user_input
test ! -z "$user_input" && sc_principal_name_01="$user_input"

# Principal name 02
sc_principal_name_02=$(get_existing_stack_value_or_default $sc_stack_name "PrincipalName02" "")
read -p "(Optional, leave blank to skip) Additional IAM role name or permission set that can access the Service Catalog product [$sc_principal_name_02]: " user_input
test ! -z "$user_input" && sc_principal_name_02="$user_input"

echo "Make sure you are logged into the correct AWS account and region, and press enter to start the installation..."
read x


# Create bucket that will contain the product template:
sam deploy \
  --template-file $sc_bucket_template_filename \
  --no-fail-on-empty-changeset \
  --on-failure DELETE \
  --stack-name $bucket_stack_name
bucket=$(get_stack_output $bucket_stack_name BucketName)
s3_url=$(get_stack_output $bucket_stack_name BucketURL)


# Replace placeholders in the template, and upload to bucket:
cp $sc_product_template_filename $sc_product_temporary_filename
sed -i.bak \
  -e "s/UseLambda: 'Yes'/UseLambda: \"$use_lambda\"/g" \
  $sc_product_temporary_filename

# Replace UTC timezone with given timezone. Timezone contains slash, so change sed char.
sed -i.bak \
  -e "s~Timezone: 'UTC'~Timezone: \"$timezone\"~g" \
  $sc_product_temporary_filename

# If using IAM Identity Center, uncomment related parameters:
if [[ "$iam_identity_center_subdomain" != "unset" ]]; then
  sed -i.bak \
    -e '/# Uncomment-if-using-IAM-Identity-Center/s/^#//g' \
    -e "s/IAMIdentityCenterSubdomain: 'unset'/IAMIdentityCenterSubdomain: $iam_identity_center_subdomain/g" \
    $sc_product_temporary_filename
fi

# If using the IAM launch role, configure permission boundaries as well:
if [[ "$sc_launch_role" == "Yes" ]]; then
  sed -i.bak \
    -e "s/UseIAMPermissionBoundary: 'No'/UseIAMPermissionBoundary: 'Yes'/g" \
    $sc_product_temporary_filename
fi

# Upload to bucket
aws s3 cp $sc_product_temporary_filename s3://${bucket}/$(basename $sc_product_template_filename)

account_id=$(aws --output text sts get-caller-identity --query Account)

# Create the Service Catalog portfolio & product:
sam deploy \
  --template-file ${sc_portfolio_template_filename} \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    ParameterKey=ProviderName,ParameterValue="$provider_name" \
    ParameterKey=ProductVersion,ParameterValue=$sc_product_version \
    ParameterKey=DeployedIAMRoleStackSet,ParameterValue=$sc_launch_role \
    ParameterKey=TemplateURL,ParameterValue=${s3_url}/$(basename $sc_product_template_filename) \
    ParameterKey=PrincipalType,ParameterValue=$sc_principal_type \
    ParameterKey=PrincipalName01,ParameterValue=$sc_principal_name_01 \
    ParameterKey=PrincipalName02,ParameterValue=$sc_principal_name_02 \
    ParameterKey=IAMIdentityCenterRegion,ParameterValue=$sc_iam_identity_center_region \
  --capabilities CAPABILITY_NAMED_IAM \
  --on-failure DELETE \
  --stack-name $sc_stack_name

echo "Stack creation finished successfully."

# Get the stack output to get the Service Catalog Product ID
product_id=$(get_stack_output $sc_stack_name ProductID)
echo "Service Catalog Product ID: $product_id"

# Sharing options, via the CLI until this is closed: https://github.com/aws-cloudformation/cloudformation-coverage-roadmap/issues/594
read -p "Enter 'org' if you want to share the portfolio to the entire Organization. Enter 'account' if you want to share with a specific account. Otherwise, enter 'n' and use the AWS Management Console to share to a specific OU. [org/account/n]: " sharing_method
portfolio_id=$(get_stack_output $sc_stack_name PortfolioID)
if [[ "$sharing_method" == "org" ]]; then
  # Share the portfolio with the org:
  organization_id=$(aws --output text organizations describe-organization --query Organization.Id)
  aws servicecatalog create-portfolio-share \
    --portfolio-id $portfolio_id \
    --share-principals \
    --organization-node Type=ORGANIZATION,Value=$organization_id
elif [[ "$sharing_method" == "account" ]]; then
  # Share the portfolio with given account:
  read -p "Enter the account ID to share with: " account_id
  aws servicecatalog create-portfolio-share \
    --portfolio-id $portfolio_id \
    --share-principals \
    --organization-node Type=ACCOUNT,Value=$account_id
fi

echo "Done!"

echo "The Service Catalog Product ID is $product_id ; use this ID if setting up the IAM Identity Center permission set CloudFormation template. This installation/update script has successfully finished."

