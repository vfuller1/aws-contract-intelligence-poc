"""
contract_intake_agent.py — Bedrock Agent action group handler for new contract intake.

Three tools the agent can call:
  extract_contract_metadata(contract_text)
      → contract type, detected clauses, rates, dates, confidence score

  get_benchmark_rates(contract_type, commodity)
      → rate range from existing Gold layer portfolio via Athena

  check_required_clauses(contract_type, detected_clauses_json)
      → missing clauses, risk tier, accept/negotiate/reject signal
"""

import json
import os
import re
import time
import boto3

REGION           = os.environ.get("AWS_REGION", "us-east-1")
ATHENA_DATABASE  = os.environ.get("ATHENA_DATABASE", "contract_intel_dev_contracts")
ATHENA_WORKGROUP = os.environ.get("ATHENA_WORKGROUP", "contract-intel-dev-contracts")

athena = boto3.client("athena", region_name=REGION)

# ---------------------------------------------------------------------------
# Clause definitions
# ---------------------------------------------------------------------------

REQUIRED_CLAUSES = {
    "PIPELINE": ["payment_terms", "force_majeure", "termination", "liability_cap",
                 "volume_commitment", "indemnification", "dispute_resolution"],
    "TERMINAL": ["payment_terms", "demurrage", "force_majeure", "termination",
                 "liability_cap", "confidentiality"],
    "MARINE":   ["payment_terms", "demurrage", "force_majeure", "termination",
                 "liability_cap", "indemnification", "dispute_resolution"],
    "RAIL":     ["payment_terms", "force_majeure", "termination",
                 "volume_commitment", "liability_cap", "dispute_resolution"],
    "TRUCKING": ["payment_terms", "termination", "liability_cap",
                 "indemnification", "confidentiality"],
}

CLAUSE_PATTERNS = {
    "payment_terms":      [r"payment", r"invoice", r"net \d+", r"due date"],
    "force_majeure":      [r"force majeure", r"act of god", r"beyond.*control"],
    "termination":        [r"terminat", r"written notice", r"\d+ days.{0,20}notice"],
    "liability_cap":      [r"liability", r"not to exceed", r"aggregate.*cap", r"maximum liability"],
    "volume_commitment":  [r"minimum.*volume", r"volume commitment", r"take.or.pay",
                           r"minimum.*barrel", r"minimum.*train", r"throughput"],
    "indemnification":    [r"indemnif", r"hold harmless", r"defend"],
    "dispute_resolution": [r"arbitrat", r"dispute", r"governing law", r"mediat"],
    "demurrage":          [r"demurrage", r"laytime", r"dispatch"],
    "confidentiality":    [r"confidential", r"non.disclosure", r"proprietary"],
}

TYPE_KEYWORDS = {
    "PIPELINE": ["pipeline", "crude oil", "throughput", "barrels per day"],
    "TERMINAL": ["terminal", "storage", "tank farm"],
    "MARINE":   ["marine", "charter", "vessel", "voyage", "lng", "liquefied"],
    "RAIL":     ["rail", "railroad", "unit train", "boxcar", "freight bill"],
    "TRUCKING": ["truck", "trucking", "loaded mile", "motor carrier", "dot"],
}


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

def extract_contract_metadata(contract_text: str) -> dict:
    text_lower = contract_text.lower()

    # Detect contract type
    contract_type = "UNKNOWN"
    best = 0
    for ctype, keywords in TYPE_KEYWORDS.items():
        score = sum(1 for k in keywords if k in text_lower)
        if score > best:
            best = score
            contract_type = ctype

    # Detect clauses
    detected = {}
    for clause, patterns in CLAUSE_PATTERNS.items():
        hits = sum(1 for p in patterns if re.search(p, text_lower))
        detected[clause] = hits > 0

    # Extract rate mentions
    rate_hits = re.findall(
        r"\$[\d,]+(?:\.\d+)?(?:\s*/\s*|\s+per\s+)\w[\w /]*",
        contract_text, re.IGNORECASE
    )

    # Extract dates
    dates = re.findall(
        r"\b(?:January|February|March|April|May|June|July|August|September|"
        r"October|November|December)\s+\d{1,2},?\s+\d{4}\b",
        contract_text, re.IGNORECASE
    )

    required = REQUIRED_CLAUSES.get(contract_type, [])
    missing  = [c for c in required if not detected.get(c, False)]
    present  = sum(1 for v in detected.values() if v)
    confidence = round(0.5 + (present / len(detected)) * 0.5, 3) if detected else 0.5

    return {
        "contract_type":         contract_type,
        "detected_clauses":      {k: v for k, v in detected.items() if v},
        "missing_clauses":       missing,
        "missing_clause_count":  len(missing),
        "rates_found":           list(dict.fromkeys(rate_hits))[:4],
        "dates_found":           list(dict.fromkeys(dates))[:4],
        "extraction_confidence": confidence,
        "word_count":            len(contract_text.split()),
    }


def _run_athena(sql: str) -> list:
    resp    = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": ATHENA_DATABASE},
        WorkGroup=ATHENA_WORKGROUP,
    )
    exec_id = resp["QueryExecutionId"]
    for _ in range(30):
        state = athena.get_query_execution(QueryExecutionId=exec_id
                    )["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            return []
        time.sleep(2)

    rows   = athena.get_query_results(QueryExecutionId=exec_id)["ResultSet"]["Rows"]
    if len(rows) < 2:
        return []
    header = [c["VarCharValue"] for c in rows[0]["Data"]]
    return [dict(zip(header, [c.get("VarCharValue", "") for c in r["Data"]])) for r in rows[1:]]


def get_benchmark_rates(contract_type: str, commodity: str = "") -> dict:
    sql = f"""
    SELECT
        contract_type,
        COUNT(DISTINCT contract_id) AS contract_count,
        MIN(contract_value)         AS min_rate,
        MAX(contract_value)         AS max_rate
    FROM {ATHENA_DATABASE}.contracts
    WHERE chunk_index = 0
      AND UPPER(contract_type) = '{contract_type.upper()}'
    GROUP BY contract_type
    """
    rows = _run_athena(sql)
    if not rows:
        return {
            "benchmark_available": False,
            "contract_type": contract_type,
            "note": "No existing contracts of this type in the portfolio for comparison.",
        }

    r = rows[0]
    return {
        "benchmark_available":      True,
        "contract_type":            contract_type,
        "existing_contract_count":  int(r.get("contract_count", 0)),
        "portfolio_rate_range": {
            "min": r.get("min_rate", "N/A"),
            "max": r.get("max_rate", "N/A"),
        },
        "note": "Compare the new contract rate against this range to assess whether it is in-market.",
    }


def check_required_clauses(contract_type: str, detected_clauses_json: str) -> dict:
    try:
        detected = json.loads(detected_clauses_json)
    except Exception:
        detected = {}

    required = REQUIRED_CLAUSES.get(contract_type.upper(), [])
    missing  = [c for c in required if not detected.get(c, False)]

    risk_score = len(missing)
    if risk_score >= 2:
        risk_tier      = "HIGH"
        recommendation = "REJECT / HOLD — multiple required clauses absent. Do not execute until resolved."
    elif risk_score == 1:
        risk_tier      = "MEDIUM"
        recommendation = f"NEGOTIATE — request insertion of '{missing[0]}' clause before signing."
    else:
        risk_tier      = "LOW"
        recommendation = "ACCEPT — all required clauses present and terms appear standard."

    return {
        "contract_type":   contract_type,
        "required_clauses": required,
        "missing_clauses":  missing,
        "missing_count":    len(missing),
        "risk_tier":        risk_tier,
        "risk_score":       risk_score,
        "recommendation":   recommendation,
    }


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def handler(event, context):
    action_group = event.get("actionGroup", "")
    function     = event.get("function", "")
    parameters   = {p["name"]: p["value"] for p in event.get("parameters", [])}

    try:
        if function == "extract_contract_metadata":
            result = extract_contract_metadata(parameters.get("contract_text", ""))
        elif function == "get_benchmark_rates":
            result = get_benchmark_rates(
                parameters.get("contract_type", ""),
                parameters.get("commodity", ""),
            )
        elif function == "check_required_clauses":
            result = check_required_clauses(
                parameters.get("contract_type", ""),
                parameters.get("detected_clauses_json", "{}"),
            )
        else:
            result = {"error": f"Unknown function: {function}"}
    except Exception as exc:
        result = {"error": str(exc)}

    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": action_group,
            "function":    function,
            "functionResponse": {
                "responseBody": {
                    "TEXT": {"body": json.dumps(result)}
                }
            },
        },
    }
