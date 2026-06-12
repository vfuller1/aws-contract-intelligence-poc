-- ============================================================================
-- CONTRACT INTELLIGENCE — VALUE LEAKAGE QUERY LIBRARY
--
-- Database  : contract_intel_dev_contracts
-- Table     : contracts  (Glue crawler over Gold S3 layer)
-- Workgroup : contract-intel-dev-contracts
-- Engine    : Athena engine version 3 (Trino)
--
-- Gold schema fields (one JSON record per chunk):
--   contract_id          string
--   contract_type        string  (PIPELINE | TERMINAL | MARINE | RAIL | TRUCKING)
--   chunk_index          int     (0-based; use chunk_index = 0 for per-contract queries)
--   total_chunks         int
--   text                 string
--   effective_date       string  ('June 12, 2026')
--   expiry_date          string  ('December 09, 2026')
--   contract_value       string  ('$85,000')
--   missing_clauses      array<string>
--   missing_clause_count int
--   pricing_anomaly      boolean
--   extraction_confidence double  (0.0 – 1.0)
--   extracted_at         string  (ISO-8601)
--   s3_bronze_key        string
--   s3_silver_key        string
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Q1: PORTFOLIO RISK SUMMARY
-- One row per contract type. Headline slide for any executive briefing.
-- ----------------------------------------------------------------------------
SELECT
    contract_type,
    COUNT(DISTINCT contract_id)                                           AS total_contracts,
    SUM(CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END)           AS contracts_missing_clauses,
    SUM(CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END)            AS pricing_anomaly_flags,
    SUM(CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END)       AS low_confidence_count,
    ROUND(AVG(extraction_confidence), 3)                                  AS avg_confidence,
    -- Composite risk: any contract with 2+ leakage signals
    SUM(CASE
          WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
              + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
              + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) >= 2
          THEN 1 ELSE 0
        END)                                                              AS high_risk_contracts
FROM contract_intel_dev_contracts.contracts
WHERE chunk_index = 0   -- one representative row per contract
GROUP BY contract_type
ORDER BY contracts_missing_clauses DESC, pricing_anomaly_flags DESC;


-- ----------------------------------------------------------------------------
-- Q2: MISSING CLAUSE DETAIL
-- Every contract that is missing at least one required clause.
-- Surface for legal / contract management review.
-- ----------------------------------------------------------------------------
SELECT
    contract_id,
    contract_type,
    missing_clause_count,
    array_join(missing_clauses, ', ')   AS missing_clause_names,
    extraction_confidence,
    effective_date,
    expiry_date,
    contract_value
FROM contract_intel_dev_contracts.contracts
WHERE chunk_index = 0
  AND missing_clause_count > 0
ORDER BY missing_clause_count DESC, extraction_confidence ASC;


-- ----------------------------------------------------------------------------
-- Q3: MISSING CLAUSE DISTRIBUTION
-- Which clause types are most frequently absent across the portfolio?
-- Drives prioritization of remediation effort.
-- ----------------------------------------------------------------------------
SELECT
    clause_name,
    COUNT(*)                                        AS contracts_missing,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_of_flagged
FROM contract_intel_dev_contracts.contracts
CROSS JOIN UNNEST(missing_clauses) AS t(clause_name)
WHERE chunk_index = 0
  AND missing_clause_count > 0
GROUP BY clause_name
ORDER BY contracts_missing DESC;


-- ----------------------------------------------------------------------------
-- Q4: PRICING ANOMALY CONTRACTS
-- Contracts where pricing clause is absent or pricing/volume signals conflict.
-- Directly quantifies value leakage exposure.
-- ----------------------------------------------------------------------------
SELECT
    contract_id,
    contract_type,
    contract_value,
    pricing_anomaly,
    missing_clause_count,
    array_join(missing_clauses, ', ')   AS missing_clause_names,
    extraction_confidence
FROM contract_intel_dev_contracts.contracts
WHERE chunk_index = 0
  AND pricing_anomaly = true
ORDER BY contract_type, contract_id;


-- ----------------------------------------------------------------------------
-- Q5: NEAR-EXPIRY CONTRACTS (string-sort — safe with 'Month DD, YYYY' format)
-- Use the agent for natural-language expiry queries when dates need parsing.
-- Upgrade: normalize expiry_date to ISO in ETL for full date arithmetic.
-- ----------------------------------------------------------------------------
SELECT
    contract_id,
    contract_type,
    effective_date,
    expiry_date,
    missing_clause_count,
    pricing_anomaly,
    contract_value
FROM contract_intel_dev_contracts.contracts
WHERE chunk_index = 0
  AND expiry_date IS NOT NULL
ORDER BY expiry_date ASC;


-- ----------------------------------------------------------------------------
-- Q6: LOW-CONFIDENCE EXTRACTIONS  (< 0.75)
-- These contracts had poor PDF quality or sparse clause coverage.
-- Flag for human review before acting on the extracted data.
-- ----------------------------------------------------------------------------
SELECT
    contract_id,
    contract_type,
    ROUND(extraction_confidence, 3)     AS confidence,
    missing_clause_count,
    array_join(missing_clauses, ', ')   AS missing_clause_names,
    s3_silver_key,
    extracted_at
FROM contract_intel_dev_contracts.contracts
WHERE chunk_index = 0
  AND extraction_confidence < 0.75
ORDER BY extraction_confidence ASC;


-- ----------------------------------------------------------------------------
-- Q7: COMPOSITE VALUE LEAKAGE SCORE
-- Risk score per contract: 0–3 signals (missing clauses, pricing anomaly,
-- low confidence). Score 2+ = high risk, 1 = medium, 0 = clean.
-- ----------------------------------------------------------------------------
SELECT
    contract_id,
    contract_type,
    contract_value,
    expiry_date,
    ROUND(extraction_confidence, 3)                             AS confidence,
    missing_clause_count,
    pricing_anomaly,
    -- Risk score (0 = clean, 1 = medium, 2-3 = high)
    (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
   + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
   + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) AS leakage_score,
    CASE
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) >= 2 THEN 'HIGH'
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) = 1  THEN 'MEDIUM'
        ELSE 'CLEAN'
    END                                                         AS risk_level
FROM contract_intel_dev_contracts.contracts
WHERE chunk_index = 0
ORDER BY leakage_score DESC, contract_type;


-- ----------------------------------------------------------------------------
-- Q8: FULL PORTFOLIO RISK REGISTER
-- Everything in one view — export to CSV for stakeholder reporting.
-- ----------------------------------------------------------------------------
SELECT
    contract_id,
    contract_type,
    contract_value,
    effective_date,
    expiry_date,
    ROUND(extraction_confidence, 3)                             AS confidence,
    missing_clause_count,
    array_join(missing_clauses, ', ')                           AS missing_clause_names,
    pricing_anomaly,
    (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
   + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
   + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) AS leakage_score,
    CASE
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) >= 2 THEN 'HIGH'
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) = 1  THEN 'MEDIUM'
        ELSE 'CLEAN'
    END                                                         AS risk_level,
    extracted_at
FROM contract_intel_dev_contracts.contracts
WHERE chunk_index = 0
ORDER BY leakage_score DESC, contract_type, contract_id;
