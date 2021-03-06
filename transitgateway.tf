# ------------------------------------------------------------------------------
# Create the Transit Gateway that will allow inter-VPC communication
# in the COOL, and share it with the other accounts that are allowed
# to access it.  Finally, attach the shared services VPC to the
# Transit Gateway.
# ------------------------------------------------------------------------------

resource "aws_ec2_transit_gateway" "tgw" {
  # We can't perform this action until our policy is in place, so we
  # need this dependency.
  depends_on = [
    aws_iam_role_policy_attachment.provisionnetworking_policy_attachment
  ]

  auto_accept_shared_attachments = "enable"
  description                    = var.transit_gateway_description
  tags                           = var.tags
}

#
# Create a shared resource for the Transit Gateway.  See
# https://aws.amazon.com/ram/ for more details about this.
#
resource "aws_ram_resource_share" "tgw" {
  # We can't perform this action until our policy is in place, so we
  # need this dependency.
  depends_on = [
    aws_iam_role_policy_attachment.provisionnetworking_policy_attachment
  ]

  allow_external_principals = true
  name                      = "SharedServices-TransitGateway"
  tags                      = var.tags
}
resource "aws_ram_resource_association" "tgw" {
  resource_arn       = aws_ec2_transit_gateway.tgw.arn
  resource_share_arn = aws_ram_resource_share.tgw.id
}

#
# Share the resource with the other accounts that are allowed to
# access it (currently the env* accounts).
#
data "aws_organizations_organization" "cool" {
  provider = aws.organizationsreadonly
}
data "aws_caller_identity" "main" {
}
locals {
  # Get Shared Services account ID from the main provider
  this_account_id = data.aws_caller_identity.main.account_id

  # Look up Shared Services account name from AWS organizations
  # provider
  this_account_name = [
    for account in data.aws_organizations_organization.cool.accounts :
    account.name
    if account.id == local.this_account_id
  ][0]

  # Determine Shared Services account type based on account name.
  #
  # The account name format is "ACCOUNT_NAME (ACCOUNT_TYPE)" - for
  # example, "Shared Services (Production)".
  this_account_type = length(regexall("\\(([^()]*)\\)", local.this_account_name)) == 1 ? regex("\\(([^()]*)\\)", local.this_account_name)[0] : "Unknown"

  # Determine the env* accounts of the same type
  env_accounts_same_type = {
    for account in data.aws_organizations_organization.cool.accounts :
    account.id => account.name
    if length(regexall("env[0-9]+ \\((${local.this_account_type})\\)", account.name)) > 0
  }
}
resource "aws_ram_principal_association" "tgw" {
  for_each = local.env_accounts_same_type

  principal          = each.key
  resource_share_arn = aws_ram_resource_share.tgw.id
}

#
# Create a route table for each account that is allowed to attach to
# the Transit Gateway.  Each of these route tables only allows traffic
# to flow between the shared services VPC and the account that is
# allowed to attach to the Transit Gateway.  This way the accounts are
# isolated from each other.
#
resource "aws_ec2_transit_gateway_route_table" "tgw_attachments" {
  for_each = local.env_accounts_same_type

  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
}
# Add routes to Shared Services to the route tables
resource "aws_ec2_transit_gateway_route" "sharedservices_routes" {
  for_each = local.env_accounts_same_type

  destination_cidr_block         = aws_vpc.the_vpc.cidr_block
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_attachments[each.key].id
}
# The routes to the individual accounts are added at the time of
# attachment.  The TGW attachment ID and CIDR block are required, and
# we don't have that information here.
