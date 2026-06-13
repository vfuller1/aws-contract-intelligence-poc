# ---------------------------------------------------------------------------
# Contract Intake Agent — Bedrock Agent + Lambda action group
# Evaluates new vendor contracts and produces ACCEPT / NEGOTIATE / REJECT
# ---------------------------------------------------------------------------

# Lambda zip for action group
data "archive_file" "contract_intake_agent" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/contract_intake_agent.py"
  output_path = "${path.module}/../../lambda/contract_intake_agent.zip"
}

# Lambda function — reuses existing ETL role (S3 + Athena + KMS)
resource "aws_lambda_function" "contract_intake_agent" {
  function_name    = "${local.prefix}-contract-intake-agent"
  role             = aws_iam_role.lambda_etl.arn
  handler          = "contract_intake_agent.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.contract_intake_agent.output_path
  source_code_hash = data.archive_file.contract_intake_agent.output_base64sha256

  environment {
    variables = {
      ATHENA_DATABASE  = aws_glue_catalog_database.contracts.name
      ATHENA_WORKGROUP = aws_athena_workgroup.contracts.name
    }
  }
}

resource "aws_cloudwatch_log_group" "intake_agent" {
  name              = "/aws/lambda/${local.prefix}-contract-intake-agent"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.main.arn
}

# IAM role for the Bedrock Agent itself
resource "aws_iam_role" "bedrock_agent" {
  name = "${local.prefix}-bedrock-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_agent_policy" {
  name = "${local.prefix}-bedrock-agent-policy"
  role = aws_iam_role.bedrock_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "*"
      },
      {
        Sid      = "InvokeLambdaActionGroup"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.contract_intake_agent.arn]
      }
    ]
  })
}

# Allow Bedrock to invoke the action group Lambda
resource "aws_lambda_permission" "bedrock_agent_invoke" {
  statement_id   = "AllowBedrockAgentInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.contract_intake_agent.function_name
  principal      = "bedrock.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# Bedrock Agent
resource "aws_bedrockagent_agent" "contract_intake" {
  agent_name              = "${local.prefix}-contract-intake"
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  idle_session_ttl_in_seconds = 600

  instruction = <<-EOT
    You are a supply chain contract intake specialist for FuelMobil.
    Your job is to review new vendor contracts and produce a clear ACCEPT, NEGOTIATE, or REJECT recommendation.

    When given a contract, follow this sequence exactly:
    1. Call extract_contract_metadata with the full contract text to identify type, clauses, rates, and confidence.
    2. Call get_benchmark_rates with the detected contract_type to compare against existing portfolio rates.
    3. Call check_required_clauses with the contract_type and a JSON object of detected clauses (true/false per clause).
    4. Synthesize all findings into a structured intake report.

    Your final report must follow this format:
    CONTRACT OVERVIEW
      - Type, commodity, key rates found, effective/expiry dates
    CLAUSE ANALYSIS
      - Clauses present, clauses missing, risk tier (LOW / MEDIUM / HIGH)
    RATE BENCHMARK
      - New contract rate vs portfolio range, assessment (below market / in range / above market)
    RECOMMENDATION: ACCEPT / NEGOTIATE / REJECT
      - Specific actions required if not ACCEPT
    CONFIDENCE
      - Extraction confidence score and any caveats
  EOT

  depends_on = [aws_iam_role_policy.bedrock_agent_policy]
}

# Action group with three tools
resource "aws_bedrockagent_agent_action_group" "contract_tools" {
  agent_id          = aws_bedrockagent_agent.contract_intake.id
  agent_version     = "DRAFT"
  action_group_name = "ContractIntakeTools"

  action_group_executor {
    lambda = aws_lambda_function.contract_intake_agent.arn
  }

  function_schema {
    member_functions {
      functions {
        name        = "extract_contract_metadata"
        description = "Extract structured metadata from raw contract text: type, clauses, rates, dates, and confidence score."
        parameters = {
          contract_text = {
            type        = "string"
            description = "The full raw text of the contract document to analyze."
            required    = true
          }
        }
      }

      functions {
        name        = "get_benchmark_rates"
        description = "Query the FuelMobil Gold layer portfolio for historical rate benchmarks for a given contract type."
        parameters = {
          contract_type = {
            type        = "string"
            description = "Contract type: PIPELINE, TERMINAL, MARINE, RAIL, or TRUCKING."
            required    = true
          }
          commodity = {
            type        = "string"
            description = "Commodity being transported e.g. Crude Oil, LNG, Refined Products."
            required    = false
          }
        }
      }

      functions {
        name        = "check_required_clauses"
        description = "Check whether all required clauses are present and return missing clauses with risk tier and recommendation."
        parameters = {
          contract_type = {
            type        = "string"
            description = "Contract type: PIPELINE, TERMINAL, MARINE, RAIL, or TRUCKING."
            required    = true
          }
          detected_clauses_json = {
            type        = "string"
            description = "JSON object mapping clause name to boolean: e.g. {\"payment_terms\": true, \"force_majeure\": false}"
            required    = true
          }
        }
      }
    }
  }

  depends_on = [aws_lambda_permission.bedrock_agent_invoke]
}

output "contract_intake_agent_id"   { value = aws_bedrockagent_agent.contract_intake.id }
