# ---------------------------------------------------------------------------
# CloudWatch — log groups, metric filters, dashboard, alarms, SNS
# ---------------------------------------------------------------------------

locals {
  log_groups = {
    router           = "/aws/lambda/${local.prefix}-router"
    bronze_to_silver = "/aws/lambda/${local.prefix}-etl-bronze-to-silver"
    silver_to_gold   = "/aws/lambda/${local.prefix}-etl-silver-to-gold"
    contract_agent   = "/aws/contract-intel/${local.prefix}-agent"
  }
}

resource "aws_cloudwatch_log_group" "lambda_logs" {
  for_each          = local.log_groups
  name              = each.value
  retention_in_days = 90
  kms_key_id        = aws_kms_key.main.arn
}

# ---------------------------------------------------------------------------
# SNS — alarm notifications
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name              = "${local.prefix}-alarms"
  kms_master_key_id = aws_kms_key.main.arn
}

# ---------------------------------------------------------------------------
# Metric Filters — extract structured metrics from agent logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "guardrail_blocked" {
  name           = "${local.prefix}-guardrail-blocked"
  pattern        = "{ $.guardrail_action = \"BLOCKED\" }"
  log_group_name = aws_cloudwatch_log_group.lambda_logs["contract_agent"].name

  metric_transformation {
    name          = "GuardrailBlocked"
    namespace     = "ContractIntel/Guardrails"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "guardrail_allowed" {
  name           = "${local.prefix}-guardrail-allowed"
  pattern        = "{ $.guardrail_action = \"ALLOWED\" }"
  log_group_name = aws_cloudwatch_log_group.lambda_logs["contract_agent"].name

  metric_transformation {
    name          = "GuardrailAllowed"
    namespace     = "ContractIntel/Guardrails"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "agent_latency" {
  name           = "${local.prefix}-agent-latency"
  pattern        = "{ $.latency_ms = * }"
  log_group_name = aws_cloudwatch_log_group.lambda_logs["contract_agent"].name

  metric_transformation {
    name          = "AgentLatencyMs"
    namespace     = "ContractIntel/Performance"
    value         = "$.latency_ms"
    default_value = "0"
    unit          = "Milliseconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "tokens_used" {
  name           = "${local.prefix}-tokens-used"
  pattern        = "{ $.total_tokens = * }"
  log_group_name = aws_cloudwatch_log_group.lambda_logs["contract_agent"].name

  metric_transformation {
    name          = "TotalTokens"
    namespace     = "ContractIntel/Cost"
    value         = "$.total_tokens"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "contracts_processed" {
  name           = "${local.prefix}-contracts-processed"
  pattern        = "{ $.event = \"CONTRACT_GOLD_COMPLETE\" }"
  log_group_name = aws_cloudwatch_log_group.lambda_logs["silver_to_gold"].name

  metric_transformation {
    name          = "ContractsProcessed"
    namespace     = "ContractIntel/ETL"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "etl_errors" {
  name           = "${local.prefix}-etl-errors"
  pattern        = "{ $.level = \"ERROR\" }"
  log_group_name = aws_cloudwatch_log_group.lambda_logs["bronze_to_silver"].name

  metric_transformation {
    name          = "ETLErrors"
    namespace     = "ContractIntel/ETL"
    value         = "1"
    default_value = "0"
  }
}

# ---------------------------------------------------------------------------
# Alarms
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "high_block_rate" {
  alarm_name          = "${local.prefix}-high-guardrail-block-rate"
  alarm_description   = "Guardrail block rate exceeds 20% — possible prompt injection campaign"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 20
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "block_rate"
    expression  = "100 * blocked / (blocked + allowed)"
    label       = "Block Rate %"
    return_data = true
  }
  metric_query {
    id = "blocked"
    metric {
      metric_name = "GuardrailBlocked"
      namespace   = "ContractIntel/Guardrails"
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id = "allowed"
    metric {
      metric_name = "GuardrailAllowed"
      namespace   = "ContractIntel/Guardrails"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "agent_latency_slo" {
  alarm_name          = "${local.prefix}-agent-latency-slo-breach"
  alarm_description   = "Agent P99 latency exceeded 10s SLO"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AgentLatencyMs"
  namespace           = "ContractIntel/Performance"
  period              = 300
  statistic           = "p99"
  threshold           = 10000
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "etl_error_spike" {
  alarm_name          = "${local.prefix}-etl-error-spike"
  alarm_description   = "ETL error count exceeded threshold — contract processing may be failing"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ETLErrors"
  namespace           = "ContractIntel/ETL"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "contract_intel" {
  dashboard_name = "${local.prefix}-ops"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x = 0; y = 0; width = 24; height = 2
        properties = {
          markdown = "# Contract Intelligence — Operations Dashboard\n**Stack:** Bedrock + Lambda + Glue + Athena | **Env:** ${var.environment} | **Region:** ${var.aws_region}"
        }
      },
      {
        type   = "metric"
        x = 0; y = 2; width = 6; height = 6
        properties = {
          title  = "Guardrail Outcomes"
          view   = "pie"
          period = 3600
          metrics = [
            ["ContractIntel/Guardrails", "GuardrailAllowed", { label = "Allowed", color = "#2ca02c" }],
            ["ContractIntel/Guardrails", "GuardrailBlocked", { label = "Blocked", color = "#d62728" }]
          ]
        }
      },
      {
        type   = "metric"
        x = 6; y = 2; width = 9; height = 6
        properties = {
          title  = "Agent Latency P50 / P90 / P99 vs 10s SLO"
          view   = "timeSeries"
          period = 300
          metrics = [
            ["ContractIntel/Performance", "AgentLatencyMs", { stat = "p50", label = "P50", color = "#1f77b4" }],
            ["ContractIntel/Performance", "AgentLatencyMs", { stat = "p90", label = "P90", color = "#ff7f0e" }],
            ["ContractIntel/Performance", "AgentLatencyMs", { stat = "p99", label = "P99", color = "#d62728" }]
          ]
          annotations = {
            horizontal = [{ value = 10000, label = "10s SLO", color = "#d62728" }]
          }
        }
      },
      {
        type   = "metric"
        x = 15; y = 2; width = 9; height = 6
        properties = {
          title  = "Token Throughput"
          view   = "timeSeries"
          period = 300
          metrics = [
            ["ContractIntel/Cost", "TotalTokens", { stat = "Sum", label = "Tokens / 5min" }]
          ]
        }
      },
      {
        type   = "metric"
        x = 0; y = 8; width = 8; height = 6
        properties = {
          title  = "Contracts Processed (ETL)"
          view   = "timeSeries"
          period = 3600
          metrics = [
            ["ContractIntel/ETL", "ContractsProcessed", { stat = "Sum", label = "Contracts / hr", color = "#2ca02c" }]
          ]
        }
      },
      {
        type   = "metric"
        x = 8; y = 8; width = 8; height = 6
        properties = {
          title  = "ETL Errors"
          view   = "timeSeries"
          period = 300
          metrics = [
            ["ContractIntel/ETL", "ETLErrors", { stat = "Sum", label = "Errors", color = "#d62728" }]
          ]
        }
      },
      {
        type   = "alarm"
        x = 16; y = 8; width = 8; height = 6
        properties = {
          title  = "Active Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.high_block_rate.arn,
            aws_cloudwatch_metric_alarm.agent_latency_slo.arn,
            aws_cloudwatch_metric_alarm.etl_error_spike.arn
          ]
        }
      }
    ]
  })
}

output "cloudwatch_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${local.prefix}-ops"
}
