"""
router.py — Bronze S3 trigger handler
Invoked by S3 event on PDF upload to Bronze bucket.
Routes to etl_bronze_to_silver Lambda.
"""

import json
import logging
import os
import boto3
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

lambda_client = boto3.client("lambda")
dynamodb = boto3.resource("dynamodb")

STATE_TABLE = os.environ["STATE_TABLE"]
ETL_FUNCTION = os.environ["ETL_FUNCTION"]

# Contract type detection from S3 key prefix
CONTRACT_TYPE_MAP = {
    "pipeline":  "PIPELINE",
    "terminal":  "TERMINAL",
    "marine":    "MARINE",
    "rail":      "RAIL",
    "trucking":  "TRUCKING",
}


def detect_contract_type(s3_key: str) -> str:
    key_lower = s3_key.lower()
    for prefix, contract_type in CONTRACT_TYPE_MAP.items():
        if prefix in key_lower:
            return contract_type
    return "UNKNOWN"


def handler(event, context):
    table = dynamodb.Table(STATE_TABLE)
    results = []

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        size = record["s3"]["object"].get("size", 0)
        contract_type = detect_contract_type(key)

        # Derive contract_id from filename (strip extension)
        filename = key.split("/")[-1]
        contract_id = filename.replace(".pdf", "").replace(" ", "_")

        logger.info(json.dumps({
            "event": "CONTRACT_RECEIVED",
            "contract_id": contract_id,
            "contract_type": contract_type,
            "s3_key": key,
            "size_bytes": size,
        }))

        # Write initial state to DynamoDB
        table.put_item(Item={
            "contract_id": contract_id,
            "processing_stage": "BRONZE",
            "contract_type": contract_type,
            "s3_bronze_key": key,
            "s3_bucket": bucket,
            "received_at": datetime.now(timezone.utc).isoformat(),
            "status": "PENDING",
        })

        # Invoke Bronze → Silver ETL asynchronously
        payload = {
            "contract_id": contract_id,
            "contract_type": contract_type,
            "s3_bucket": bucket,
            "s3_key": key,
        }

        lambda_client.invoke(
            FunctionName=ETL_FUNCTION,
            InvocationType="Event",  # async
            Payload=json.dumps(payload),
        )

        results.append({
            "contract_id": contract_id,
            "contract_type": contract_type,
            "status": "ROUTED",
        })

    logger.info(json.dumps({"event": "ROUTER_COMPLETE", "routed": len(results)}))
    return {"statusCode": 200, "body": results}
