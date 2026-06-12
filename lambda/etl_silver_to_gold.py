"""
etl_silver_to_gold.py — Silver → Gold ETL
Chunks Silver JSON into 2,000-char segments with metadata,
writes to Gold S3, optionally triggers Bedrock KB ingestion.
"""

import json
import logging
import os
import boto3
from datetime import datetime, timezone
from typing import Generator

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
bedrock_agent = boto3.client("bedrock-agent")

SILVER_BUCKET = os.environ["SILVER_BUCKET"]
GOLD_BUCKET = os.environ["GOLD_BUCKET"]
STATE_TABLE = os.environ["STATE_TABLE"]
KNOWLEDGE_BASE_ID = os.environ.get("KNOWLEDGE_BASE_ID", "")
DATA_SOURCE_ID = os.environ.get("DATA_SOURCE_ID", "")

CHUNK_SIZE = 2000
CHUNK_OVERLAP = 200


def chunk_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> Generator[str, None, None]:
    """Sliding window chunker — yields overlapping text segments."""
    if not text:
        return
    start = 0
    while start < len(text):
        end = start + chunk_size
        yield text[start:end]
        if end >= len(text):
            break
        start = end - overlap


def score_extraction_confidence(silver_doc: dict) -> float:
    """
    Heuristic confidence score for extraction quality.
    Based on word count, clause detection rate, and page count.
    Returns 0.0 – 1.0
    """
    score = 0.0

    # Word count signal
    words = silver_doc.get("total_words", 0)
    if words > 500:
        score += 0.3
    elif words > 100:
        score += 0.15

    # Clause detection signal
    detected = silver_doc.get("detected_clauses", {})
    present = sum(1 for v in detected.values() if v.get("present"))
    total = len(detected) or 1
    score += 0.4 * (present / total)

    # Missing clauses penalty
    missing = silver_doc.get("missing_clause_count", 0)
    score -= missing * 0.05

    # Page count signal
    pages = silver_doc.get("total_pages", 0)
    if pages >= 3:
        score += 0.3
    elif pages >= 1:
        score += 0.15

    return max(0.0, min(1.0, round(score, 3)))


def detect_pricing_anomaly(silver_doc: dict) -> bool:
    """
    Flag contract if pricing clause is absent or metadata has no contract value.
    Simplified heuristic — extend with ML scoring for production.
    """
    clauses = silver_doc.get("detected_clauses", {})
    pricing_present = clauses.get("pricing", {}).get("present", False)
    volume_present = clauses.get("volume_commitment", {}).get("present", False)
    contract_value = silver_doc.get("metadata", {}).get("contract_value_raw")
    return not pricing_present or (volume_present and not contract_value)


def handler(event, context):
    # Can be invoked directly with contract_id + silver_key,
    # or via SQS/EventBridge with the same payload.
    contract_id = event["contract_id"]
    silver_key = event.get("silver_key", f"contracts/{contract_id}/silver.json")

    table = dynamodb.Table(STATE_TABLE)

    logger.info(json.dumps({
        "event": "ETL_SILVER_START",
        "contract_id": contract_id,
        "silver_key": silver_key,
    }))

    try:
        # Read Silver document
        obj = s3.get_object(Bucket=SILVER_BUCKET, Key=silver_key)
        silver_doc = json.loads(obj["Body"].read())

        contract_type = silver_doc["contract_type"]
        full_text = silver_doc["full_text"]
        metadata = silver_doc.get("metadata", {})
        missing_clauses = silver_doc.get("missing_clauses", [])

        # Score extraction confidence
        confidence = score_extraction_confidence(silver_doc)
        pricing_anomaly = detect_pricing_anomaly(silver_doc)

        # Build Gold chunks
        chunks = list(chunk_text(full_text))
        gold_records = []

        for i, chunk in enumerate(chunks):
            gold_record = {
                "contract_id": contract_id,
                "contract_type": contract_type,
                "chunk_index": i,
                "total_chunks": len(chunks),
                "text": chunk,
                "char_count": len(chunk),
                # Metadata for Athena queries and RAG retrieval
                "effective_date": metadata.get("effective_date"),
                "expiry_date": metadata.get("expiry_date"),
                "contract_value": metadata.get("contract_value_raw"),
                "missing_clauses": missing_clauses,
                "missing_clause_count": len(missing_clauses),
                "pricing_anomaly": pricing_anomaly,
                "extraction_confidence": confidence,
                "extracted_at": datetime.now(timezone.utc).isoformat(),
                # S3 lineage
                "s3_bronze_key": silver_doc.get("s3_bronze_key"),
                "s3_silver_key": silver_key,
            }
            gold_records.append(gold_record)

        # Write each chunk as newline-delimited JSON to Gold
        gold_key = f"contracts/{contract_type.lower()}/{contract_id}/gold.jsonl"
        body = "\n".join(json.dumps(r, ensure_ascii=False) for r in gold_records)

        s3.put_object(
            Bucket=GOLD_BUCKET,
            Key=gold_key,
            Body=body,
            ContentType="application/x-ndjson",
        )

        # Update DynamoDB state
        table.put_item(Item={
            "contract_id": contract_id,
            "processing_stage": "GOLD",
            "contract_type": contract_type,
            "s3_gold_key": gold_key,
            "chunk_count": len(chunks),
            "extraction_confidence": str(confidence),
            "pricing_anomaly": pricing_anomaly,
            "missing_clause_count": len(missing_clauses),
            "status": "COMPLETE",
            "processed_at": datetime.now(timezone.utc).isoformat(),
        })

        logger.info(json.dumps({
            "event": "CONTRACT_GOLD_COMPLETE",
            "contract_id": contract_id,
            "contract_type": contract_type,
            "chunk_count": len(chunks),
            "extraction_confidence": confidence,
            "pricing_anomaly": pricing_anomaly,
            "missing_clauses": missing_clauses,
            "gold_key": gold_key,
        }))

        # Trigger Bedrock KB ingestion if RAG is enabled
        if KNOWLEDGE_BASE_ID and DATA_SOURCE_ID:
            bedrock_agent.start_ingestion_job(
                knowledgeBaseId=KNOWLEDGE_BASE_ID,
                dataSourceId=DATA_SOURCE_ID,
            )
            logger.info(json.dumps({
                "event": "KB_INGESTION_TRIGGERED",
                "contract_id": contract_id,
                "knowledge_base_id": KNOWLEDGE_BASE_ID,
            }))

        return {
            "statusCode": 200,
            "contract_id": contract_id,
            "gold_key": gold_key,
            "chunk_count": len(chunks),
            "extraction_confidence": confidence,
            "pricing_anomaly": pricing_anomaly,
            "missing_clauses": missing_clauses,
        }

    except Exception as e:
        logger.error(json.dumps({
            "level": "ERROR",
            "event": "ETL_SILVER_FAILED",
            "contract_id": contract_id,
            "error": str(e),
        }))

        table.update_item(
            Key={"contract_id": contract_id, "processing_stage": "SILVER"},
            UpdateExpression="SET #s = :s, error_message = :e",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "FAILED", ":e": str(e)},
        )
        raise
