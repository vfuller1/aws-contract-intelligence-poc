"""
etl_bronze_to_silver.py — Bronze → Silver ETL
Extracts raw text from contract PDFs, detects clause structure,
and writes structured JSON to the Silver bucket.
"""

import json
import logging
import os
import re
import boto3
import pdfplumber
from datetime import datetime, timezone
from io import BytesIO

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")

BRONZE_BUCKET = os.environ["BRONZE_BUCKET"]
SILVER_BUCKET = os.environ["SILVER_BUCKET"]
STATE_TABLE = os.environ["STATE_TABLE"]

# Clause patterns for supply chain contracts
CLAUSE_PATTERNS = {
    "payment_terms":     r"(?i)(payment\s+terms?|net\s+\d+\s+days?|invoice\s+due)",
    "demurrage":         r"(?i)(demurrage|laytime|dispatch)",
    "force_majeure":     r"(?i)(force\s+majeure|act\s+of\s+god|unforeseeable)",
    "termination":       r"(?i)(termination|terminate|cancellation\s+clause)",
    "liability_cap":     r"(?i)(limitation\s+of\s+liability|liability\s+cap|maximum\s+liability)",
    "indemnification":   r"(?i)(indemnif|hold\s+harmless)",
    "dispute_resolution":r"(?i)(arbitration|dispute\s+resolution|governing\s+law)",
    "confidentiality":   r"(?i)(confidential|non-disclosure|proprietary\s+information)",
    "pricing":           r"(?i)(rate\s+schedule|unit\s+price|\$[\d,]+|tariff)",
    "volume_commitment": r"(?i)(minimum\s+volume|throughput\s+commitment|take-or-pay)",
}

REQUIRED_CLAUSES = {
    "PIPELINE":  ["payment_terms", "force_majeure", "termination", "liability_cap", "volume_commitment"],
    "TERMINAL":  ["payment_terms", "force_majeure", "termination", "liability_cap", "demurrage"],
    "MARINE":    ["payment_terms", "demurrage", "force_majeure", "termination", "liability_cap"],
    "RAIL":      ["payment_terms", "force_majeure", "termination", "volume_commitment"],
    "TRUCKING":  ["payment_terms", "termination", "liability_cap"],
    "UNKNOWN":   ["payment_terms", "termination"],
}


def extract_text_from_pdf(pdf_bytes: bytes) -> list[dict]:
    """Extract text page by page using pdfplumber."""
    pages = []
    with pdfplumber.open(BytesIO(pdf_bytes)) as pdf:
        for i, page in enumerate(pdf.pages):
            text = page.extract_text() or ""
            pages.append({
                "page_number": i + 1,
                "text": text,
                "word_count": len(text.split()),
            })
    return pages


def detect_clauses(full_text: str) -> dict:
    """Detect presence of standard contract clauses."""
    found = {}
    for clause_name, pattern in CLAUSE_PATTERNS.items():
        matches = re.findall(pattern, full_text)
        found[clause_name] = {
            "present": len(matches) > 0,
            "match_count": len(matches),
        }
    return found


def identify_missing_clauses(detected: dict, contract_type: str) -> list[str]:
    """Compare detected clauses against required clauses for contract type."""
    required = REQUIRED_CLAUSES.get(contract_type, REQUIRED_CLAUSES["UNKNOWN"])
    return [c for c in required if not detected.get(c, {}).get("present", False)]


def extract_metadata(full_text: str, contract_id: str) -> dict:
    """Extract key metadata fields from contract text."""
    metadata = {"contract_id": contract_id}

    # Effective date
    date_match = re.search(r"(?i)effective\s+(?:date[:\s]+)?(\w+\s+\d+,?\s+\d{4})", full_text)
    metadata["effective_date"] = date_match.group(1) if date_match else None

    # Expiry / term
    expiry_match = re.search(r"(?i)(?:expir(?:y|ation)|term\s+end)[:\s]+(\w+\s+\d+,?\s+\d{4})", full_text)
    metadata["expiry_date"] = expiry_match.group(1) if expiry_match else None

    # Contract value (first dollar amount found)
    value_match = re.search(r"\$\s*([\d,]+(?:\.\d{2})?)", full_text)
    metadata["contract_value_raw"] = value_match.group(0) if value_match else None

    return metadata


def handler(event, context):
    contract_id = event["contract_id"]
    contract_type = event["contract_type"]
    s3_key = event["s3_key"]
    bucket = event["s3_bucket"]

    table = dynamodb.Table(STATE_TABLE)

    logger.info(json.dumps({
        "event": "ETL_BRONZE_START",
        "contract_id": contract_id,
        "contract_type": contract_type,
        "s3_key": s3_key,
    }))

    try:
        # Read PDF from Bronze
        obj = s3.get_object(Bucket=bucket, Key=s3_key)
        pdf_bytes = obj["Body"].read()

        # Extract text
        pages = extract_text_from_pdf(pdf_bytes)
        full_text = " ".join(p["text"] for p in pages)
        total_words = sum(p["word_count"] for p in pages)

        # Detect clauses and missing clauses
        detected_clauses = detect_clauses(full_text)
        missing_clauses = identify_missing_clauses(detected_clauses, contract_type)

        # Extract metadata
        metadata = extract_metadata(full_text, contract_id)

        # Build Silver document
        silver_doc = {
            "contract_id": contract_id,
            "contract_type": contract_type,
            "s3_bronze_key": s3_key,
            "pages": pages,
            "full_text": full_text,
            "total_pages": len(pages),
            "total_words": total_words,
            "detected_clauses": detected_clauses,
            "missing_clauses": missing_clauses,
            "missing_clause_count": len(missing_clauses),
            "metadata": metadata,
            "extracted_at": datetime.now(timezone.utc).isoformat(),
        }

        # Write to Silver
        silver_key = f"contracts/{contract_type.lower()}/{contract_id}/silver.json"
        s3.put_object(
            Bucket=SILVER_BUCKET,
            Key=silver_key,
            Body=json.dumps(silver_doc, ensure_ascii=False),
            ContentType="application/json",
        )

        # Update DynamoDB state
        table.put_item(Item={
            "contract_id": contract_id,
            "processing_stage": "SILVER",
            "contract_type": contract_type,
            "s3_silver_key": silver_key,
            "total_pages": len(pages),
            "total_words": total_words,
            "missing_clause_count": len(missing_clauses),
            "missing_clauses": missing_clauses,
            "status": "COMPLETE",
            "processed_at": datetime.now(timezone.utc).isoformat(),
        })

        logger.info(json.dumps({
            "event": "ETL_BRONZE_COMPLETE",
            "contract_id": contract_id,
            "total_pages": len(pages),
            "total_words": total_words,
            "missing_clauses": missing_clauses,
            "silver_key": silver_key,
        }))

        return {
            "statusCode": 200,
            "contract_id": contract_id,
            "silver_key": silver_key,
            "missing_clauses": missing_clauses,
        }

    except Exception as e:
        logger.error(json.dumps({
            "level": "ERROR",
            "event": "ETL_BRONZE_FAILED",
            "contract_id": contract_id,
            "error": str(e),
        }))

        table.update_item(
            Key={"contract_id": contract_id, "processing_stage": "BRONZE"},
            UpdateExpression="SET #s = :s, error_message = :e",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "FAILED", ":e": str(e)},
        )
        raise
