"""
portfolio_report.py — Contract portfolio value leakage report

Queries Athena over the Gold S3 layer and prints a structured risk report.
Requires the Glue crawler to have run at least once after ETL completes.

Usage:
    python scripts/analytics/portfolio_report.py
    python scripts/analytics/portfolio_report.py --output report.json
    python scripts/analytics/portfolio_report.py --database contract_intel_dev_contracts --workgroup contract-intel-dev-contracts
"""

import argparse
import json
import logging
import os
import sys
import time
import boto3
from datetime import datetime, timezone

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

logging.basicConfig(level=logging.WARNING)
logger = logging.getLogger(__name__)

REGION        = os.environ.get("AWS_REGION", "us-east-1")
DATABASE      = os.environ.get("ATHENA_DATABASE",  "contract_intel_dev_contracts")
WORKGROUP     = os.environ.get("ATHENA_WORKGROUP",  "contract-intel-dev-contracts")
TABLE         = "contracts"
POLL_INTERVAL = 2   # seconds between execution status checks
QUERY_TIMEOUT = 120 # seconds before giving up on a query

athena = boto3.client("athena", region_name=REGION)


# ---------------------------------------------------------------------------
# Athena query runner
# ---------------------------------------------------------------------------

def run_query(sql: str, desc: str = "") -> list[dict]:
    """Execute SQL on Athena, wait for completion, return rows as list of dicts."""
    resp = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": DATABASE},
        WorkGroup=WORKGROUP,
    )
    execution_id = resp["QueryExecutionId"]

    deadline = time.time() + QUERY_TIMEOUT
    while time.time() < deadline:
        status = athena.get_query_execution(QueryExecutionId=execution_id)
        state  = status["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            reason = status["QueryExecution"]["Status"].get("StateChangeReason", "unknown")
            raise RuntimeError(f"Athena query {desc!r} {state}: {reason}")
        time.sleep(POLL_INTERVAL)
    else:
        raise TimeoutError(f"Athena query {desc!r} timed out after {QUERY_TIMEOUT}s")

    paginator = athena.get_paginator("get_query_results")
    rows = []
    header = None
    for page in paginator.paginate(QueryExecutionId=execution_id):
        result_rows = page["ResultSet"]["Rows"]
        if header is None:
            header = [col["VarCharValue"] for col in result_rows[0]["Data"]]
            result_rows = result_rows[1:]
        for row in result_rows:
            values = [cell.get("VarCharValue", "") for cell in row["Data"]]
            rows.append(dict(zip(header, values)))
    return rows


# ---------------------------------------------------------------------------
# Individual report sections
# ---------------------------------------------------------------------------

PORTFOLIO_SUMMARY_SQL = f"""
SELECT
    contract_type,
    COUNT(DISTINCT contract_id)                                             AS total_contracts,
    SUM(CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END)             AS contracts_missing_clauses,
    SUM(CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END)              AS pricing_anomaly_flags,
    SUM(CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END)         AS low_confidence_count,
    ROUND(AVG(extraction_confidence), 3)                                    AS avg_confidence
FROM {DATABASE}.{TABLE}
WHERE chunk_index = 0
GROUP BY contract_type
ORDER BY contracts_missing_clauses DESC, pricing_anomaly_flags DESC
"""

RISK_REGISTER_SQL = f"""
SELECT
    contract_id,
    contract_type,
    contract_value,
    effective_date,
    expiry_date,
    ROUND(extraction_confidence, 3)                                          AS confidence,
    missing_clause_count,
    array_join(missing_clauses, ', ')                                        AS missing_clause_names,
    CAST(pricing_anomaly AS VARCHAR)                                         AS pricing_anomaly,
    (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
   + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
   + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END)              AS leakage_score,
    CASE
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) >= 2 THEN 'HIGH'
        WHEN (CASE WHEN missing_clause_count > 0 THEN 1 ELSE 0 END
            + CASE WHEN pricing_anomaly = true  THEN 1 ELSE 0 END
            + CASE WHEN extraction_confidence < 0.75 THEN 1 ELSE 0 END) = 1  THEN 'MEDIUM'
        ELSE 'CLEAN'
    END                                                                      AS risk_level
FROM {DATABASE}.{TABLE}
WHERE chunk_index = 0
ORDER BY leakage_score DESC, contract_type
"""

CLAUSE_DISTRIBUTION_SQL = f"""
SELECT
    clause_name,
    COUNT(*) AS contracts_missing
FROM {DATABASE}.{TABLE}
CROSS JOIN UNNEST(missing_clauses) AS t(clause_name)
WHERE chunk_index = 0
  AND missing_clause_count > 0
GROUP BY clause_name
ORDER BY contracts_missing DESC
"""


# ---------------------------------------------------------------------------
# Report rendering
# ---------------------------------------------------------------------------

def _divider(char: str = "─", width: int = 68) -> str:
    return char * width


def print_report(summary: list[dict], register: list[dict], clause_dist: list[dict]):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    high   = [r for r in register if r.get("risk_level") == "HIGH"]
    medium = [r for r in register if r.get("risk_level") == "MEDIUM"]
    clean  = [r for r in register if r.get("risk_level") == "CLEAN"]

    print("\n" + "=" * 68)
    print("  CONTRACT INTELLIGENCE — PORTFOLIO VALUE LEAKAGE REPORT")
    print(f"  Generated: {now}")
    print("=" * 68)

    # ---- Portfolio Summary ----
    print(f"\n{'PORTFOLIO SUMMARY BY MODALITY':}")
    print(_divider())
    fmt = f"  {'Type':<12} {'Contracts':>9} {'Missing Clauses':>16} {'Pricing Anomaly':>16} {'Avg Confidence':>15}"
    print(fmt)
    print(_divider())
    for row in summary:
        print(
            f"  {row['contract_type']:<12}"
            f"  {row['total_contracts']:>8}"
            f"  {row['contracts_missing_clauses']:>15}"
            f"  {row['pricing_anomaly_flags']:>15}"
            f"  {float(row['avg_confidence']):.3f}{'':>10}"
        )
    print(_divider())

    # ---- Risk Distribution ----
    total = len(register)
    print(f"\nRISK DISTRIBUTION  ({total} contracts total)")
    print(_divider())
    print(f"  HIGH   (2+ leakage signals): {len(high):>3}  {'█' * len(high)}")
    print(f"  MEDIUM (1 leakage signal):   {len(medium):>3}  {'█' * len(medium)}")
    print(f"  CLEAN  (no signals):         {len(clean):>3}  {'█' * len(clean)}")
    print(_divider())

    # ---- High Risk Contracts ----
    if high:
        print(f"\nHIGH-RISK CONTRACTS  (immediate review required)")
        print(_divider())
        for r in high:
            print(f"  {r['contract_id']:<25} {r['contract_type']:<10} score={r['leakage_score']}")
            if r.get("missing_clause_names"):
                print(f"    Missing clauses : {r['missing_clause_names']}")
            if r.get("pricing_anomaly") == "true":
                print(f"    Pricing anomaly : YES")
            print(f"    Confidence      : {float(r['confidence']):.3f}  |  Expiry: {r.get('expiry_date','N/A')}")
        print(_divider())

    # ---- Medium Risk ----
    if medium:
        print(f"\nMEDIUM-RISK CONTRACTS  (schedule review)")
        print(_divider())
        for r in medium:
            flag = r.get("missing_clause_names") or ("pricing anomaly" if r.get("pricing_anomaly") == "true" else "low confidence")
            print(f"  {r['contract_id']:<25} {r['contract_type']:<10} flag: {flag}")
        print(_divider())

    # ---- Clause Distribution ----
    if clause_dist:
        print(f"\nMOST COMMONLY MISSING CLAUSES")
        print(_divider())
        for row in clause_dist:
            bar = "█" * int(row["contracts_missing"])
            print(f"  {row['clause_name']:<22} {row['contracts_missing']:>2} contract(s)  {bar}")
        print(_divider())

    # ---- Clean Contracts ----
    print(f"\nCLEAN CONTRACTS  (no value leakage signals)")
    print(_divider())
    for r in clean:
        print(f"  {r['contract_id']:<25} {r['contract_type']:<10} confidence={float(r['confidence']):.3f}")
    print(_divider())

    print(f"\nSUMMARY: {len(high)} HIGH | {len(medium)} MEDIUM | {len(clean)} CLEAN out of {total} contracts\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global DATABASE, WORKGROUP
    parser = argparse.ArgumentParser(description="Contract portfolio value leakage report")
    parser.add_argument("--database",  default=DATABASE,  help="Glue database name")
    parser.add_argument("--workgroup", default=WORKGROUP, help="Athena workgroup")
    parser.add_argument("--output",    default=None,      help="Save raw results to JSON file")
    args = parser.parse_args()

    DATABASE  = args.database
    WORKGROUP = args.workgroup

    print(f"Querying Athena — database: {DATABASE}, workgroup: {WORKGROUP}")

    try:
        print("  Running portfolio summary...")
        summary = run_query(PORTFOLIO_SUMMARY_SQL, "portfolio-summary")

        print("  Running risk register...")
        register = run_query(RISK_REGISTER_SQL, "risk-register")

        print("  Running clause distribution...")
        clause_dist = run_query(CLAUSE_DISTRIBUTION_SQL, "clause-distribution")
    except RuntimeError as e:
        print(f"\nERROR: {e}")
        print("\nMake sure the Glue crawler has run after ETL completes:")
        print("  aws glue start-crawler --name contract-intel-dev-gold-crawler")
        return

    print_report(summary, register, clause_dist)

    if args.output:
        payload = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "database": DATABASE,
            "workgroup": WORKGROUP,
            "portfolio_summary": summary,
            "risk_register": register,
            "clause_distribution": clause_dist,
        }
        with open(args.output, "w") as f:
            json.dump(payload, f, indent=2)
        print(f"Raw results saved to {args.output}")


if __name__ == "__main__":
    main()
