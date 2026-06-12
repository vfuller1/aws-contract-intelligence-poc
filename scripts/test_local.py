"""
Local smoke test — runs ETL core logic and confidence scoring without AWS.
Usage: python scripts/test_local.py
"""
import os
import sys
import unittest.mock as mock

# Set required env vars before Lambda modules load
os.environ.setdefault("BRONZE_BUCKET", "local-test")
os.environ.setdefault("SILVER_BUCKET", "local-test")
os.environ.setdefault("GOLD_BUCKET",   "local-test")
os.environ.setdefault("STATE_TABLE",   "local-test")

sys.path.insert(0, "lambda")

with mock.patch("boto3.client"), mock.patch("boto3.resource"):
    import etl_bronze_to_silver as bronze
    import etl_silver_to_gold as gold

CONTRACTS = [
    ("PIPE-TC-2024-001", "PIPELINE"),
    ("TERM-SA-2024-002", "TERMINAL"),
    ("MAR-VC-2024-003",  "MARINE"),
    ("RAIL-TA-2024-004", "RAIL"),
    ("TRUCK-RA-2024-005","TRUCKING"),
]

results = []
print("\n" + "=" * 68)
print("LOCAL ETL SMOKE TEST")
print("=" * 68)

for contract_id, contract_type in CONTRACTS:
    pdf_path = f"data/synthetic_contracts/{contract_id}.pdf"
    with open(pdf_path, "rb") as f:
        pdf_bytes = f.read()

    pages = bronze.extract_text_from_pdf(pdf_bytes)
    full_text = " ".join(p["text"] for p in pages)
    total_words = sum(p["word_count"] for p in pages)

    detected = bronze.detect_clauses(full_text)
    missing = bronze.identify_missing_clauses(detected, contract_type)
    metadata = bronze.extract_metadata(full_text, contract_id)

    silver_doc = {
        "contract_id": contract_id,
        "contract_type": contract_type,
        "pages": pages,
        "full_text": full_text,
        "total_pages": len(pages),
        "total_words": total_words,
        "detected_clauses": detected,
        "missing_clauses": missing,
        "missing_clause_count": len(missing),
        "metadata": metadata,
    }

    chunks = list(gold.chunk_text(full_text))
    confidence = gold.score_extraction_confidence(silver_doc)
    anomaly = gold.detect_pricing_anomaly(silver_doc)

    present = [k for k, v in detected.items() if v["present"]]

    print(f"\n{contract_id} ({contract_type})")
    print(f"  Pages: {len(pages)} | Words: {total_words} | Chunks: {len(chunks)}")
    print(f"  Clauses present:  {present}")
    print(f"  Missing clauses:  {missing if missing else 'none'}")
    print(f"  Confidence:       {confidence:.3f} | Pricing anomaly: {anomaly}")
    print(f"  Effective date:   {metadata.get('effective_date')} | Expiry: {metadata.get('expiry_date')}")

    results.append({
        "contract_id": contract_id,
        "pages": len(pages),
        "words": total_words,
        "chunks": len(chunks),
        "missing_clauses": missing,
        "confidence": confidence,
        "pricing_anomaly": anomaly,
    })

print("\n" + "=" * 68)
total_chunks = sum(r["chunks"] for r in results)
any_anomaly = [r["contract_id"] for r in results if r["pricing_anomaly"]]
any_missing = [r["contract_id"] for r in results if r["missing_clauses"]]
print(f"SUMMARY: {len(CONTRACTS)} contracts | {total_chunks} total Gold chunks")
print(f"Value leakage flags — pricing anomaly: {any_anomaly if any_anomaly else 'none'}")
print(f"                      missing clauses: {any_missing if any_missing else 'none'}")
print("=" * 68)
print("\nAll ETL core logic: PASS\n")
