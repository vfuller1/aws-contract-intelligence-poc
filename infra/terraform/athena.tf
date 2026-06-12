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
  description = "Portfolio risk summary by contract type — missing clauses, pricing anomalies, confidence"

  query = <<-SQL
    SELECT
      contract_type,
      COUNT(DISTINCT contract_id)                                           AS total_contracts,
      SUM(CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END)           AS contracts_missing_clauses,
      SUM(CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END)            AS pricing_anomaly_flags,
      SUM(CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END)       AS low_confidence_count,
      ROUND(AVG(extraction_confidence), 3)                                  AS avg_confidence
    FROM ${aws_glue_catalog_database.contracts.name}.contracts
    WHERE chunk_index = 0
    GROUP BY contract_type
    ORDER BY contracts_missing_clauses DESC, pricing_anomaly_flags DESC
  SQL
}

resource "aws_athena_named_query" "value_leakage_risk_register" {
  name        = "value-leakage-risk-register"
  workgroup   = aws_athena_workgroup.contracts.id
  database    = aws_glue_catalog_database.contracts.name
  description = "Full portfolio risk register with composite leakage score per contract"

  query = <<-SQL
    SELECT
      contract_id,
      contract_type,
      contract_value,
      effective_date,
      expiry_date,
      ROUND(extraction_confidence, 3)                                        AS confidence,
      missing_clause_count,
      array_join(missing_clauses, ', ')                                      AS missing_clause_names,
      CAST(pricing_anomaly AS VARCHAR)                                       AS pricing_anomaly,
      (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
     + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
     + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END)            AS leakage_score,
      CASE
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) >= 2 THEN 'HIGH'
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) = 1  THEN 'MEDIUM'
        ELSE 'CLEAN'
      END                                                                    AS risk_level
    FROM ${aws_glue_catalog_database.contracts.name}.contracts
    WHERE chunk_index = 0
    ORDER BY leakage_score DESC, contract_type
  SQL
}

resource "aws_athena_named_query" "low_confidence_extractions" {
  name        = "low-confidence-extractions"
  workgroup   = aws_athena_workgroup.contracts.id
  database    = aws_glue_catalog_database.contracts.name
  description = "Contracts where AI extraction confidence < 0.75 — flag for human review"

  query = <<-SQL
    SELECT
      contract_id,
      contract_type,
      ROUND(extraction_confidence, 3)    AS confidence,
      missing_clause_count,
      array_join(missing_clauses, ', ')  AS missing_clause_names,
      s3_silver_key,
      extracted_at
    FROM ${aws_glue_catalog_database.contracts.name}.contracts
    WHERE chunk_index = 0
      AND extraction_confidence < 0.75
    ORDER BY extraction_confidence ASC
  SQL
}

resource "aws_athena_named_query" "missing_clause_distribution" {
  name        = "missing-clause-distribution"
  workgroup   = aws_athena_workgroup.contracts.id
  database    = aws_glue_catalog_database.contracts.name
  description = "Which clause types are most commonly absent across the portfolio"

  query = <<-SQL
    SELECT
      clause_name,
      COUNT(*) AS contracts_missing
    FROM ${aws_glue_catalog_database.contracts.name}.contracts
    CROSS JOIN UNNEST(missing_clauses) AS t(clause_name)
    WHERE chunk_index = 0
      AND missing_clause_count > 0
    GROUP BY clause_name
    ORDER BY contracts_missing DESC
  SQL
}

output "athena_workgroup_name" { value = aws_athena_workgroup.contracts.name }
