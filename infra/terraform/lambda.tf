# ---------------------------------------------------------------------------
# IAM — Lambda execution roles (least-privilege)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_etl" {
  name               = "${local.prefix}-lambda-etl-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "lambda_etl_policy" {
  name = "${local.prefix}-lambda-etl-policy"
  role = aws_iam_role.lambda_etl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3LakehouseAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
        ]
        Resource = flatten([
          for k, b in aws_s3_bucket.lakehouse : [b.arn, "${b.arn}/*"]
        ])
      },
      {
        Sid      = "DynamoDBState"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.contract_state.arn
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.prefix}-*:*"
      },
      {
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda Functions
# ---------------------------------------------------------------------------

# Packaging — zip each lambda from source
data "archive_file" "router" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/router.py"
  output_path = "${path.module}/../../lambda/dist/router.zip"
}

data "archive_file" "etl_bronze_to_silver" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/etl_bronze_to_silver.py"
  output_path = "${path.module}/../../lambda/dist/etl_bronze_to_silver.zip"
}

data "archive_file" "etl_silver_to_gold" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/etl_silver_to_gold.py"
  output_path = "${path.module}/../../lambda/dist/etl_silver_to_gold.zip"
}

# Router Lambda — triggered by S3 Bronze on PDF upload
resource "aws_lambda_function" "router" {
  function_name    = "${local.prefix}-router"
  role             = aws_iam_role.lambda_etl.arn
  filename         = data.archive_file.router.output_path
  source_code_hash = data.archive_file.router.output_base64sha256
  handler          = "router.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      SILVER_BUCKET    = aws_s3_bucket.lakehouse["silver"].bucket
      STATE_TABLE      = aws_dynamodb_table.contract_state.name
      ETL_FUNCTION     = "${local.prefix}-etl-bronze-to-silver"
    }
  }

  kms_key_arn = aws_kms_key.main.arn
}

# ETL Bronze → Silver Lambda
resource "aws_lambda_function" "etl_bronze_to_silver" {
  function_name    = "${local.prefix}-etl-bronze-to-silver"
  role             = aws_iam_role.lambda_etl.arn
  filename         = data.archive_file.etl_bronze_to_silver.output_path
  source_code_hash = data.archive_file.etl_bronze_to_silver.output_base64sha256
  handler          = "etl_bronze_to_silver.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 512

  environment {
    variables = {
      BRONZE_BUCKET = aws_s3_bucket.lakehouse["bronze"].bucket
      SILVER_BUCKET = aws_s3_bucket.lakehouse["silver"].bucket
      STATE_TABLE   = aws_dynamodb_table.contract_state.name
    }
  }

  kms_key_arn = aws_kms_key.main.arn
}

# ETL Silver → Gold Lambda
resource "aws_lambda_function" "etl_silver_to_gold" {
  function_name    = "${local.prefix}-etl-silver-to-gold"
  role             = aws_iam_role.lambda_etl.arn
  filename         = data.archive_file.etl_silver_to_gold.output_path
  source_code_hash = data.archive_file.etl_silver_to_gold.output_base64sha256
  handler          = "etl_silver_to_gold.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 512

  environment {
    variables = {
      SILVER_BUCKET = aws_s3_bucket.lakehouse["silver"].bucket
      GOLD_BUCKET   = aws_s3_bucket.lakehouse["gold"].bucket
      STATE_TABLE   = aws_dynamodb_table.contract_state.name
    }
  }

  kms_key_arn = aws_kms_key.main.arn
}

# Allow S3 to invoke the router
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.lakehouse["bronze"].arn
}

output "router_function_name"           { value = aws_lambda_function.router.function_name }
output "etl_bronze_to_silver_function"  { value = aws_lambda_function.etl_bronze_to_silver.function_name }
output "etl_silver_to_gold_function"    { value = aws_lambda_function.etl_silver_to_gold.function_name }
