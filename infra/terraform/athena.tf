# ---------------------------------------------------------------------------
# Amazon Athena — query layer over Glue-catalogued Gold data
# ---------------------------------------------------------------------------

resource "aws_athena_workgroup" "contracts" {
  name        = "${local.prefix}-contracts"
  description = "Contract intelligence analytics workgroup"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lakehouse["athena"].bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.main.arn
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }
}

# ---------------------------------------------------------------------------
# Named Queries — pre-built value leakage analytics
# ---------------------------------------------------------------------------

resource "aws_athena_named_query" "value_leakage_summary" {
  name        = "value-leakage-summary"
  workgroup   = aws_athena_workgroup.contracts.id
  database    = aws_glue_catalog_database.contracts.name
  description = "Summarize contracts with non-standard pricing terms or missing clauses"

  query = <<-SQL
    SELECT
      contract_type,
      COUNT(*) AS total_contracts,
      SUM(CASE WHEN missing_clauses > 0 THEN 1 ELSE 0 END) AS contracts_with_missing_clauses,
      SUM(CASE WHEN pricing_anomaly = true THEN 1 ELSE 0 END) AS pricing_anomalies,
      AVG(extraction_confidence) AS avg_confidence
    FROM contracts
    GROUP BY contract_type
    ORDER BY pricing_anomalies DESC
  SQL
}

resource "aws_athena_named_query" "pipeline_contracts_review" {
  name        = "pipeline-contracts-review"
  workgroup   = aws_athena_workgroup.contracts.id
  database    = aws_glue_catalog_database.contracts.name
  description = "Review all pipeline contracts for value leakage indicators"

  query = <<-SQL
    SELECT
      contract_id,
      vendor_id,
      effective_date,
      expiry_date,
      contract_value,
      missing_clauses,
      pricing_anomaly,
      extraction_confidence,
      extracted_at
    FROM contracts
    WHERE contract_type = 'PIPELINE'
      AND (missing_clauses > 0 OR pricing_anomaly = true)
    ORDER BY contract_value DESC
  SQL
}

resource "aws_athena_named_query" "low_confidence_extractions" {
  name        = "low-confidence-extractions"
  workgroup   = aws_athena_workgroup.contracts.id
  database    = aws_glue_catalog_database.contracts.name
  description = "Identify contracts where AI extraction confidence is below threshold — needs human review"

  query = <<-SQL
    SELECT
      contract_id,
      contract_type,
      extraction_confidence,
      missing_clauses,
      s3_gold_path,
      extracted_at
    FROM contracts
    WHERE extraction_confidence < 0.75
    ORDER BY extraction_confidence ASC
  SQL
}

resource "aws_athena_named_query" "expiring_contracts" {
  name        = "expiring-contracts-90-days"
  workgroup   = aws_athena_workgroup.contracts.id
  database    = aws_glue_catalog_database.contracts.name
  description = "Contracts expiring within 90 days — renewal risk"

  query = <<-SQL
    SELECT
      contract_id,
      contract_type,
      vendor_id,
      contract_value,
      expiry_date,
      DATE_DIFF('day', CURRENT_DATE, DATE(expiry_date)) AS days_until_expiry
    FROM contracts
    WHERE DATE(expiry_date) BETWEEN CURRENT_DATE AND DATE_ADD('day', 90, CURRENT_DATE)
    ORDER BY expiry_date ASC
  SQL
}

output "athena_workgroup_name" { value = aws_athena_workgroup.contracts.name }
