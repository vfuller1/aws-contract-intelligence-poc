# ---------------------------------------------------------------------------
# GitHub Actions OIDC deploy role
# The OIDC provider (token.actions.githubusercontent.com) is pre-existing in
# this account — reference it via data source rather than creating a new one.
# ---------------------------------------------------------------------------

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions_deploy" {
  name        = "aws-${local.prefix}-github-actions-deploy"
  description = "Assumed by GitHub Actions via OIDC to run terraform plan/apply"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = data.aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Scoped to this repo only — any branch/ref
          "token.actions.githubusercontent.com:sub" = "repo:vfuller1/aws-contract-intelligence-poc:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "aws-${local.prefix}-github-actions-deploy-policy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # --- Terraform remote state ---
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
          "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration"
        ]
        Resource = [
          "arn:aws:s3:::aws-contract-intel-tfstate",
          "arn:aws:s3:::aws-contract-intel-tfstate/*"
        ]
      },
      {
        Sid      = "TerraformStateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/aws-contract-intel-tfstate-lock"
      },
      # --- S3 (data lake buckets) ---
      {
        Sid    = "S3DataLake"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          "arn:aws:s3:::${local.prefix}-*",
          "arn:aws:s3:::${local.prefix}-*/*"
        ]
      },
      # --- Lambda ---
      {
        Sid      = "Lambda"
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.prefix}-*"
      },
      {
        Sid      = "LambdaLayers"
        Effect   = "Allow"
        Action   = ["lambda:GetLayerVersion", "lambda:PublishLayerVersion", "lambda:DeleteLayerVersion", "lambda:ListLayerVersions"]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:layer:${local.prefix}-*"
      },
      # --- DynamoDB ---
      {
        Sid      = "DynamoDB"
        Effect   = "Allow"
        Action   = ["dynamodb:*"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.prefix}-*"
      },
      # --- Glue ---
      {
        Sid      = "Glue"
        Effect   = "Allow"
        Action   = ["glue:*"]
        Resource = "*"
      },
      # --- Athena ---
      {
        Sid      = "Athena"
        Effect   = "Allow"
        Action   = ["athena:*"]
        Resource = "*"
      },
      # --- CloudWatch Logs, Metrics, Alarms, Dashboards ---
      {
        Sid      = "CloudWatch"
        Effect   = "Allow"
        Action   = ["logs:*", "cloudwatch:*"]
        Resource = "*"
      },
      # --- SNS ---
      {
        Sid      = "SNS"
        Effect   = "Allow"
        Action   = ["sns:*"]
        Resource = "arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${local.prefix}-*"
      },
      # --- KMS ---
      {
        Sid      = "KMS"
        Effect   = "Allow"
        Action   = ["kms:*"]
        Resource = "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"
      },
      {
        Sid      = "KMSAlias"
        Effect   = "Allow"
        Action   = ["kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias", "kms:ListAliases"]
        Resource = "*"
      },
      # --- Bedrock (guardrails, knowledge base, agents) ---
      {
        Sid      = "Bedrock"
        Effect   = "Allow"
        Action   = ["bedrock:*"]
        Resource = "*"
      },
      # --- OpenSearch Serverless (RAG vector store) ---
      {
        Sid      = "OpenSearchServerless"
        Effect   = "Allow"
        Action   = ["aoss:*"]
        Resource = "*"
      },
      # --- IAM — scoped to project-prefixed roles and policies ---
      {
        Sid    = "IAMRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
          "iam:PassRole", "iam:TagRole", "iam:UntagRole",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.prefix}-*"
      },
      {
        Sid    = "IAMOIDCProvider"
        Effect = "Allow"
        Action = ["iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders"]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = "ARN to paste into secrets.AWS_ACCOUNT_ID or directly into the workflow role-to-assume"
  value       = aws_iam_role.github_actions_deploy.arn
}
