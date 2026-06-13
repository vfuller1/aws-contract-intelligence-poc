"""
intake_agent.py — New contract intake via Bedrock Agent

The agent extracts metadata, benchmarks rates against the portfolio,
checks required clauses, and returns ACCEPT / NEGOTIATE / REJECT.

Usage:
    # Review an existing seeded contract from S3
    python scripts/agent/intake_agent.py --contract-id MAR-VC-2024-003

    # Review a local contract text file
    python scripts/agent/intake_agent.py --file path/to/contract.txt

    # Pass raw text directly
    python scripts/agent/intake_agent.py --text "PIPELINE CONTRACT..."

Environment variables:
    INTAKE_AGENT_ID    — Bedrock Agent ID (from terraform output contract_intake_agent_id)
    AWS_REGION         — defaults to us-east-1
    SILVER_BUCKET      — defaults to contract-intel-dev-silver
"""

import argparse
import json
import os
import sys
import uuid
import boto3

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REGION        = os.environ.get("AWS_REGION",      "us-east-1")
AGENT_ID      = os.environ.get("INTAKE_AGENT_ID", "")
AGENT_ALIAS   = os.environ.get("INTAKE_AGENT_ALIAS", "TSTALIASID")  # DRAFT alias
SILVER_BUCKET = os.environ.get("SILVER_BUCKET",   "contract-intel-dev-silver")

bedrock_agent = boto3.client("bedrock-agent-runtime", region_name=REGION)
s3            = boto3.client("s3",                    region_name=REGION)


def fetch_from_silver(contract_id: str) -> str:
    prefixes = ["pipeline", "terminal", "marine", "rail", "trucking"]
    for prefix in prefixes:
        key = f"contracts/{prefix}/{contract_id}/silver.json"
        try:
            obj = s3.get_object(Bucket=SILVER_BUCKET, Key=key)
            doc = json.loads(obj["Body"].read())
            return doc.get("full_text", "")
        except Exception:
            continue
    raise FileNotFoundError(f"No Silver JSON for contract_id={contract_id!r}")


def invoke_agent(contract_text: str) -> str:
    if not AGENT_ID:
        raise ValueError(
            "Set INTAKE_AGENT_ID env var.\n"
            "Get it from: terraform -chdir=infra/terraform output contract_intake_agent_id"
        )

    session_id = str(uuid.uuid4())
    prompt = (
        "Please review this new vendor contract and produce a complete "
        "intake recommendation:\n\n"
        + contract_text[:8000]
    )

    response = bedrock_agent.invoke_agent(
        agentId=AGENT_ID,
        agentAliasId=AGENT_ALIAS,
        sessionId=session_id,
        inputText=prompt,
    )

    output = []
    for event in response["completion"]:
        if "chunk" in event:
            output.append(event["chunk"]["bytes"].decode("utf-8"))
    return "".join(output)


def main():
    parser = argparse.ArgumentParser(description="Contract Intake Agent — ACCEPT / NEGOTIATE / REJECT")
    parser.add_argument("--contract-id", help="Load contract text from S3 Silver layer")
    parser.add_argument("--file",        help="Path to a local contract text file")
    parser.add_argument("--text",        help="Raw contract text string")
    args = parser.parse_args()

    if args.contract_id:
        print(f"Fetching {args.contract_id} from S3 Silver...")
        contract_text = fetch_from_silver(args.contract_id)
    elif args.file:
        with open(args.file, encoding="utf-8", errors="replace") as f:
            contract_text = f.read()
    elif args.text:
        contract_text = args.text
    else:
        parser.print_help()
        return

    print(f"Invoking intake agent ({len(contract_text):,} chars)...\n")
    print("=" * 68)
    result = invoke_agent(contract_text)
    print(result)
    print("=" * 68)


if __name__ == "__main__":
    main()
