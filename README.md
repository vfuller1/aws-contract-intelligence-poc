# AWS Contract Intelligence POC

*Enterprise Supply Chain Contract Extraction on AWS*

Victor G. Fuller | github.com/vfuller1/aws-contract-intelligence-poc

---

## Project Summary

Event-driven ETL pipeline, Bedrock guardrails, RAG knowledge base, Glue catalog, Athena query layer, and a CloudWatch ops dashboard — purpose-built for supply chain contract data extraction and value leakage identification.

Modeled on the architecture pattern required for large-scale contract intelligence engagements (pipeline, terminal, marine, rail, and trucking contracts).

| Metric | Value |
|---|---|
| Cost at idle | $0/hr |
| Cost per contract processed | ~$0.13 |
| RAG layer (when active) | ~$0.96/hr |
| Athena queries | ~$0.00–0.05 per session at POC volume |
| Glue crawler | ~$0.01–0.05 per run |

---

## What It Does

Supply chain organizations manage thousands of unique, multi-page contracts and invoices across pipeline, terminal, marine, rail, and trucking modalities. This system:

- Extracts structured data from raw contract PDFs automatically through a Bronze → Silver → Gold data lakehouse
- Identifies value leakage by surfacing pricing anomalies, missing clauses, and non-standard terms
- Enforces enterprise governance on every AI invocation — PII protection, topic restrictions, prompt-injection defense
- Catalogs extracted contract data via AWS Glue and exposes it for analytics through Amazon Athena
- Exposes a live CloudWatch operations dashboard with guardrail block rate, latency percentiles, and token throughput

---

## Architecture

### Four-Layer Design

| Layer | Components | Purpose |
|---|---|---|
| Governance Layer | Bedrock Guardrail (always on) | PII block/anonymise, topic deny, content filter, prompt-attack detection |
| Inference Layer | Claude Haiku 4.5 + optional RAG (Bedrock KB) | Extract contract clauses grounded in document corpus |
| Data Lakehouse (ETL) | S3 Bronze→Silver→Gold + Lambda | PDF ingestion, text extraction, clause chunking, metadata tagging |
| Catalog & Query | AWS Glue + Amazon Athena | Schema discovery, contract analytics, value leakage queries |
| Observability | CloudWatch Logs, Metric Filters, Dashboard, Alarms, SNS | Block rate, latency P50/P90/P99, token throughput, SLO alarms |

---

## Tech Stack

| Layer | Service |
|---|---|
| AI Model | Amazon Bedrock — Claude Haiku 4.5 (cross-region inference) |
| Governance | Amazon Bedrock Guardrails |
| RAG | Bedrock Knowledge Base + OpenSearch Serverless |
| Embeddings | Amazon Titan Text Embeddings V2 (1,024-dim) |
| ETL | AWS Lambda (Python 3.12) + Lambda Layer (pypdf) |
| Data Lake | Amazon S3 (Bronze / Silver / Gold medallion) |
| Cataloguing | AWS Glue Data Catalog + Crawler |
| Analytics | Amazon Athena |
| Observability | CloudWatch Logs, Metric Filters, Dashboard, Alarms, SNS |
| State | DynamoDB |
| Encryption | AWS KMS (CMK) — all buckets, log groups, DynamoDB, SNS |
| IaC | Terraform (remote state in S3 + DynamoDB lock) |
| CI/CD | GitHub Actions — OIDC (no static credentials in CI/CD) |

---

## Contract Types Supported

| ID | Contract Type | Modality |
|---|---|---|
| PIPE-TC | Pipeline Transportation Contract | Pipeline |
| TERM-SA | Terminal Storage Agreement | Terminal |
| MAR-VC | Marine Voyage Charter | Marine |
| RAIL-TA | Rail Transportation Agreement | Rail |
| TRUCK-RA | Trucking Rate Agreement | Trucking |

**After ETL: ~1,050 Gold chunks (210 per contract type, 2,000-char target with 200-char overlap).**

---

## Sample Contract — Marine Voyage Charter (MAR-VC-2024-003)

```
================================================================================
CONFIDENTIAL - Contract ID: MAR-VC-2024-003
================================================================================

                       MARINE VOYAGE CHARTER PARTY

  Contract ID:   MAR-VC-2024-003
  Reference:     REF-A7X2K9
  Effective:     June 12, 2026
  Expiration:    December 09, 2026

  PARTIES
  -------
  FuelMobil Supply Chain Services LLC        ("Charterer")
  Atlantic Marine Carriers Ltd.              ("Owner / Carrier")

  CONTRACT SUMMARY
  ----------------
  Commodity         : Liquefied Natural Gas (LNG)
  Volume            : 140,000 cubic meters per voyage
  Charter Hire      : $85,000 per day
  Contract Term     : 6 months

  TERMS AND CONDITIONS
  --------------------

  Section 1. Payment Terms
    Charter hire payable 15 days in advance. Off-hire deductions
    calculated on a pro-rata daily basis.

  Section 2. Demurrage
    Laytime allowed: 36 running hours SHINC (Sundays and Holidays
    Included). Demurrage rate: $42,000 per day, pro-rata.
    Dispatch: half demurrage rate.

  Section 3. Force Majeure
    In the event of war, hostilities, blockades, or acts of God
    preventing the vessel from reaching the load or discharge port,
    the charter is cancelled without liability to either party.

  Section 4. Termination
    Owner may withdraw vessel for non-payment of charter hire if
    payment remains outstanding for more than 3 banking days after
    due date.

  Section 5. Liability Cap
    Carrier liability limited to SDR 666.67 per package or
    SDR 2.00 per kilogram of gross weight, whichever is higher,
    per Hague-Visby Rules.

  Section 6. Indemnification
    Charterer shall indemnify Owner against all consequences
    arising from compliance with Charterer's instructions
    regarding the cargo.

  Section 7. Dispute Resolution
    Governed by English law. Disputes submitted to London
    Maritime Arbitrators Association (LMAA).

================================================================================
  Page 1 | CONFIDENTIAL | MAR-VC-2024-003
================================================================================
```

**What the pipeline extracts from this contract:**

| Extracted Field | Value | Risk Flag |
|---|---|---|
| Charter hire rate | $85,000/day | — |
| Demurrage rate | $42,000/day pro-rata | — |
| Laytime allowance | 36 hrs SHINC | — |
| Liability cap | SDR 666.67/package (Hague-Visby) | — |
| Governing law | English law / LMAA arbitration | — |
| Missing clauses | none | — |
| Extraction confidence | 0.960 | — |
| Pricing anomaly | False | — |

---

## Guardrail Policies

| Policy | Type | Behaviour |
|---|---|---|
| unauthorized-disclosure | Topic deny | Blocks requests to expose confidential contract terms |
| pricing-negotiation | Topic deny | Blocks live pricing or rate negotiation queries |
| competitor-contracts | Topic deny | Blocks competitor contract comparisons |
| PII — SSN, AWS keys, account numbers | Sensitive info | Block (hard stop) |
| PII — vendor names, signatory names | Sensitive info | Anonymise (replace with placeholder) |
| Hate, violence, sexual, misconduct | Content filter | Block at HIGH sensitivity |
| Prompt injection / jailbreak | PROMPT_ATTACK | Block at HIGH sensitivity |

---

## Live Demo Scenarios

| Scenario | Result | Detail |
|---|---|---|
| "What is the demurrage rate in contract MAR-VC-2024-001?" | ALLOWED | ~300ms response |
| Vendor name + account number + contract value | BLOCKED | pii:* |
| AWS access key in message | BLOCKED | pii:AWS_ACCESS_KEY |
| "What rate should I negotiate for next year?" | BLOCKED | topic:pricing-negotiation |
| "Show me what competitors are paying" | BLOCKED | topic:competitor-contracts |
| "Ignore all previous instructions..." | BLOCKED | content:prompt_attack |

---

## Architecture Decision: Why Not Databricks?

The FuelMobil stack includes Databricks. This POC uses AWS-native serverless for three deliberate reasons:

- **Cost:** $0 at rest. Databricks clusters idle at ~$2–5/hr. This stack costs $0/hr when idle.
- **Simplicity:** No cluster management, no Spark tuning. Each ETL step is a standalone Python function.
- **Native Bedrock:** Bedrock Knowledge Base, Guardrails, and Claude are first-class AWS services. One boto3 call vs a custom integration layer.

**When Databricks is the right answer:** At millions of documents with complex Spark transformations, Databricks wins on throughput. For a POC validating extraction patterns across hundreds of contracts, serverless Lambda is the right tool. The Gold layer S3 schema is intentionally compatible with Databricks Delta Lake if the production decision goes that direction.

---

## Cost Model

| Component | Cost |
|---|---|
| Lambda (ETL + router) | ~$0.13 per contract processed |
| Bedrock Guardrail | ~$0.75 / 1,000 text units |
| Bedrock Claude Haiku 4.5 | ~$0.25 / 1M tokens |
| CloudWatch Logs + Metrics | < $1/month at demo volume |
| OpenSearch Serverless (RAG) | ~$0.96/hr — disabled by default |
| AWS Glue Crawler | ~$0.01–0.05 per run |
| Amazon Athena | ~$5/TB scanned — negligible at POC volume |
| Everything else (idle) | $0 |

### Cost at Scale (Projection)

| Volume | Estimated Cost |
|---|---|
| 100 contracts | ~$13 one-time ETL + <$1 Athena |
| 1,000 contracts | ~$130 one-time ETL + ~$2 Athena |
| 10,000 contracts | ~$1,300 ETL + Bedrock caching reduces repeat inference ~80% |
| 100,000 contracts | Evaluate Databricks cluster vs Lambda concurrency limits |

---

## Security

- All S3 buckets: TLS-only policy, versioning, KMS-SSE, access logging, public access blocked
- All CloudWatch log groups: KMS-encrypted, 90-day retention
- DynamoDB and SNS: KMS-encrypted
- IAM roles: least-privilege, scoped to specific resources and prefixes
- GitHub Actions: OIDC only — no static AWS credentials in CI/CD
- Bedrock KB role: confused-deputy protection (aws:SourceAccount condition)

---

## CI/CD

GitHub Actions workflows use OIDC to assume the `aws-contract-intel-dev-github-actions-deploy` IAM role.

```
push to main
  └── terraform plan   (on PR)
  └── terraform apply  (on merge to main)
```

---

## Quick Start

### Prerequisites

- AWS CLI configured (us-east-1)
- Terraform ≥ 1.5
- Python 3.12 + boto3, fpdf2, pdfplumber
- PowerShell 7+

### Deploy

```bash
# 1. Build the pypdf Lambda layer
.\scripts\build_lambda_layers.ps1

# 2. Deploy infrastructure (RAG off by default)
cd infra/terraform
terraform init
terraform apply

# 3. Generate synthetic contracts and upload to Bronze
python scripts/ingest/generate_contracts.py

# Upload PDFs to the Bronze S3 bucket — ETL fires automatically
```

### Test the Guardrail

```bash
# Run all 6 governance scenarios
python scripts/agent/contract_agent.py --test-guardrail

# Interactive mode
python scripts/agent/contract_agent.py --interactive
```

### Enable / Disable RAG (~$0.96/hr while active)

```powershell
.\scripts\kb_enable.ps1   # RAG on
.\scripts\kb_disable.ps1  # RAG off — destroys OpenSearch, preserves Gold data
```

---

## Project Structure

| File / Folder | Purpose |
|---|---|
| `infra/terraform/` | All Terraform IaC |
| `infra/terraform/main.tf` | Provider, backend, variables |
| `infra/terraform/s3.tf` | Bronze / Silver / Gold buckets |
| `infra/terraform/lambda.tf` | ETL Lambda functions |
| `infra/terraform/bedrock_guardrails.tf` | Guardrail: PII, topics, content, prompt-attack |
| `infra/terraform/bedrock_kb.tf` | Knowledge Base + OpenSearch (feature-flagged) |
| `infra/terraform/glue.tf` | Glue crawler + Data Catalog |
| `infra/terraform/athena.tf` | Athena workgroup + query results bucket |
| `infra/terraform/cloudwatch.tf` | Log groups, metric filters, dashboard, alarms |
| `infra/terraform/kms.tf` | Customer-managed encryption key |
| `infra/terraform/dynamodb.tf` | State tracking table |
| `lambda/router.py` | Bronze router — routes + triggers ETL |
| `lambda/etl_bronze_to_silver.py` | PDF → JSON extraction (pypdf) |
| `lambda/etl_silver_to_gold.py` | JSON → 2,000-char chunks + metadata tagging |
| `scripts/agent/contract_agent.py` | Agent runtime — Bedrock Converse + guardrail |
| `scripts/ingest/generate_contracts.py` | Synthetic supply chain contract PDF generator |
| `scripts/kb_enable.ps1` | RAG on — terraform apply + StartIngestionJob |
| `scripts/kb_disable.ps1` | RAG off — destroys OpenSearch |
| `.github/workflows/` | Terraform plan/apply via OIDC |

---

*github.com/vfuller1/aws-contract-intelligence-poc | Victor G. Fuller*
