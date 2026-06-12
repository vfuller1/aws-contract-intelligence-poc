"""
seed_live.py — End-to-end data seeder for the live AWS environment.

Generates synthetic PDFs, runs the full Bronze→Silver→Gold ETL locally,
uploads all three layers to S3, and writes DynamoDB processing state.
Use this to populate the environment without the pdfplumber Lambda layer.

After this runs:
  1. aws glue start-crawler --name contract-intel-dev-gold-crawler
  2. (wait ~60s for crawler to complete)
  3. python scripts/analytics/portfolio_report.py

Usage:
    python scripts/seed_live.py
"""

import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import boto3

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "lambda"))
sys.path.insert(0, str(REPO_ROOT / "scripts" / "ingest"))

REGION        = os.environ.get("AWS_REGION",      "us-east-1")
PREFIX        = "contract-intel-dev"
BRONZE_BUCKET = os.environ.get("BRONZE_BUCKET",   f"{PREFIX}-bronze")
SILVER_BUCKET = os.environ.get("SILVER_BUCKET",   f"{PREFIX}-silver")
GOLD_BUCKET   = os.environ.get("GOLD_BUCKET",     f"{PREFIX}-gold")
STATE_TABLE   = os.environ.get("STATE_TABLE",     f"{PREFIX}-contract-state")

os.environ.setdefault("BRONZE_BUCKET", BRONZE_BUCKET)
os.environ.setdefault("SILVER_BUCKET", SILVER_BUCKET)
os.environ.setdefault("GOLD_BUCKET",   GOLD_BUCKET)
os.environ.setdefault("STATE_TABLE",   STATE_TABLE)

from etl_bronze_to_silver import (
    extract_text_from_pdf, detect_clauses, identify_missing_clauses, extract_metadata,
)
from etl_silver_to_gold import (
    chunk_text, score_extraction_confidence, detect_pricing_anomaly,
)
from generate_contracts import CONTRACTS, generate_contract_pdf

s3       = boto3.client("s3",      region_name=REGION)
dynamodb = boto3.resource("dynamodb", region_name=REGION)


def seed_contract(contract: dict, tmp_dir: str) -> dict:
    contract_id   = contract["id"]
    contract_type = contract["type"].upper()
    table         = dynamodb.Table(STATE_TABLE)

    print(f"\n  [{contract_id}]  {contract_type}")

    # ---- Generate PDF ------------------------------------------------
    pdf_path = generate_contract_pdf(contract, tmp_dir)
    with open(pdf_path, "rb") as fh:
        pdf_bytes = fh.read()

    # ---- Bronze: upload PDF + write state ----------------------------
    bronze_key = f"{contract['type']}/{contract_id}.pdf"
    s3.put_object(Bucket=BRONZE_BUCKET, Key=bronze_key, Body=pdf_bytes,
                  ContentType="application/pdf")
    print(f"    Bronze  s3://{BRONZE_BUCKET}/{bronze_key}")

    table.put_item(Item={
        "contract_id":      contract_id,
        "processing_stage": "BRONZE",
        "contract_type":    contract_type,
        "s3_bronze_key":    bronze_key,
        "s3_bucket":        BRONZE_BUCKET,
        "received_at":      datetime.now(timezone.utc).isoformat(),
        "status":           "COMPLETE",
    })

    # ---- Bronze → Silver ETL (local) ---------------------------------
    pages       = extract_text_from_pdf(pdf_bytes)
    full_text   = " ".join(p["text"] for p in pages)
    total_words = sum(p["word_count"] for p in pages)

    detected_clauses = detect_clauses(full_text)
    missing_clauses  = identify_missing_clauses(detected_clauses, contract_type)
    metadata         = extract_metadata(full_text, contract_id)

    silver_doc = {
        "contract_id":          contract_id,
        "contract_type":        contract_type,
        "s3_bronze_key":        bronze_key,
        "pages":                pages,
        "full_text":            full_text,
        "total_pages":          len(pages),
        "total_words":          total_words,
        "detected_clauses":     detected_clauses,
        "missing_clauses":      missing_clauses,
        "missing_clause_count": len(missing_clauses),
        "metadata":             metadata,
        "extracted_at":         datetime.now(timezone.utc).isoformat(),
    }

    silver_key = f"contracts/{contract['type']}/{contract_id}/silver.json"
    s3.put_object(Bucket=SILVER_BUCKET, Key=silver_key,
                  Body=json.dumps(silver_doc, ensure_ascii=False),
                  ContentType="application/json")
    print(f"    Silver  s3://{SILVER_BUCKET}/{silver_key}")

    table.put_item(Item={
        "contract_id":          contract_id,
        "processing_stage":     "SILVER",
        "contract_type":        contract_type,
        "s3_silver_key":        silver_key,
        "total_pages":          len(pages),
        "total_words":          total_words,
        "missing_clause_count": len(missing_clauses),
        "missing_clauses":      missing_clauses,
        "status":               "COMPLETE",
        "processed_at":         datetime.now(timezone.utc).isoformat(),
    })

    # ---- Silver → Gold ETL (local) -----------------------------------
    confidence      = score_extraction_confidence(silver_doc)
    pricing_anomaly = detect_pricing_anomaly(silver_doc)
    chunks          = list(chunk_text(full_text))

    gold_records = []
    for i, chunk in enumerate(chunks):
        gold_records.append({
            "contract_id":           contract_id,
            "contract_type":         contract_type,
            "chunk_index":           i,
            "total_chunks":          len(chunks),
            "text":                  chunk,
            "char_count":            len(chunk),
            "effective_date":        metadata.get("effective_date"),
            "expiry_date":           metadata.get("expiry_date"),
            "contract_value":        metadata.get("contract_value_raw"),
            "missing_clauses":       missing_clauses,
            "missing_clause_count":  len(missing_clauses),
            "pricing_anomaly":       pricing_anomaly,
            "extraction_confidence": confidence,
            "extracted_at":          datetime.now(timezone.utc).isoformat(),
            "s3_bronze_key":         bronze_key,
            "s3_silver_key":         silver_key,
        })

    gold_key = f"contracts/{contract['type']}/{contract_id}/gold.jsonl"
    s3.put_object(Bucket=GOLD_BUCKET, Key=gold_key,
                  Body="\n".join(json.dumps(r, ensure_ascii=False) for r in gold_records),
                  ContentType="application/x-ndjson")
    print(f"    Gold    s3://{GOLD_BUCKET}/{gold_key}  "
          f"({len(chunks)} chunks | conf={confidence:.3f} | "
          f"missing={missing_clauses or 'none'} | anomaly={pricing_anomaly})")

    table.put_item(Item={
        "contract_id":           contract_id,
        "processing_stage":      "GOLD",
        "contract_type":         contract_type,
        "s3_gold_key":           gold_key,
        "chunk_count":           len(chunks),
        "extraction_confidence": str(confidence),
        "pricing_anomaly":       pricing_anomaly,
        "missing_clause_count":  len(missing_clauses),
        "status":                "COMPLETE",
        "processed_at":          datetime.now(timezone.utc).isoformat(),
    })

    return {
        "contract_id":    contract_id,
        "contract_type":  contract_type,
        "missing_clauses": missing_clauses,
        "confidence":     confidence,
        "pricing_anomaly": pricing_anomaly,
        "chunks":         len(chunks),
    }


def main():
    print("=" * 64)
    print("  CONTRACT INTELLIGENCE - LIVE DATA SEEDER")
    print(f"  Bronze : {BRONZE_BUCKET}")
    print(f"  Silver : {SILVER_BUCKET}")
    print(f"  Gold   : {GOLD_BUCKET}")
    print(f"  Table  : {STATE_TABLE}  |  Region: {REGION}")
    print("=" * 64)

    results = []
    with tempfile.TemporaryDirectory() as tmp:
        for contract in CONTRACTS:
            result = seed_contract(contract, tmp)
            results.append(result)

    print(f"\n{'=' * 64}")
    print(f"  Seeded {len(results)} contracts into Bronze / Silver / Gold / DynamoDB")
    print()
    print("  Next steps:")
    print("    1. aws glue start-crawler --name contract-intel-dev-gold-crawler")
    print("    2. Wait ~60s for crawler to finish cataloguing Gold JSONL files")
    print("    3. python scripts/analytics/portfolio_report.py")
    print(f"{'=' * 64}")


if __name__ == "__main__":
    main()
