# ---------------------------------------------------------------------------
# GitHub Actions OIDC — bootstrap resources (managed OUTSIDE Terraform)
#
# The OIDC provider and deploy role are pre-conditions for this Terraform
# to run at all, so they cannot be managed by this configuration.
# They were created once via targeted apply during initial bootstrap and
# must not be imported here — doing so creates a circular dependency where
# the role would need iam:GetRole on itself.
#
# Bootstrap commands (run once with admin credentials):
#   terraform apply -target=aws_iam_role.github_actions_deploy \
#                   -target=aws_iam_role_policy.github_actions_deploy
#
# Role ARN: arn:aws:iam::ACCOUNT:role/aws-contract-intel-dev-github-actions-deploy
# ---------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}
