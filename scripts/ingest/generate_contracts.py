"""
generate_contracts.py — Synthetic supply chain contract PDF generator
Generates realistic multi-page PDFs for all 5 contract types:
  PIPELINE, TERMINAL, MARINE, RAIL, TRUCKING

Usage:
    python scripts/ingest/generate_contracts.py
    python scripts/ingest/generate_contracts.py --upload --bucket YOUR_BRONZE_BUCKET
"""

import argparse
import os
import random
import string
from datetime import date, timedelta
from fpdf import FPDF
import boto3

OUTPUT_DIR = "data/synthetic_contracts"

# ---------------------------------------------------------------------------
# Contract templates per modality
# ---------------------------------------------------------------------------

CONTRACTS = [
    {
        "id": "PIPE-TC-2024-001",
        "type": "pipeline",
        "title": "Pipeline Transportation Contract",
        "vendor": "Midlands Pipeline Services LLC",
        "commodity": "Crude Oil",
        "volume_commitment": "50,000 barrels per day minimum throughput",
        "rate": "$0.42 per barrel per 100 miles",
        "term_months": 24,
        "clauses": {
            "payment_terms": "Net 30 days from invoice date. Late payments subject to 1.5% per month interest.",
            "force_majeure": "Neither party shall be liable for delays caused by acts of God, government action, "
                             "labor disputes, or other unforeseeable circumstances beyond reasonable control.",
            "termination": "Either party may terminate this agreement with 90 days written notice. "
                           "Immediate termination permitted for material breach uncured within 30 days.",
            "liability_cap": "In no event shall either party's aggregate liability exceed the total fees paid "
                             "in the twelve months preceding the claim.",
            "volume_commitment": "Shipper commits to a minimum throughput of 50,000 barrels per day. "
                                 "Failure to meet minimum is subject to take-or-pay provisions.",
            "indemnification": "Each party shall indemnify, defend, and hold harmless the other party from "
                                "and against any claims arising from its own negligence or willful misconduct.",
            "dispute_resolution": "Any dispute shall first be subject to good-faith negotiation for 30 days, "
                                   "followed by binding arbitration under AAA Commercial Rules.",
        }
    },
    {
        "id": "TERM-SA-2024-002",
        "type": "terminal",
        "title": "Terminal Storage and Throughput Agreement",
        "vendor": "Gulf Coast Terminal Operations Inc.",
        "commodity": "Refined Petroleum Products",
        "volume_commitment": "200,000 barrel storage capacity reservation",
        "rate": "$0.18 per barrel per month storage",
        "term_months": 12,
        "clauses": {
            "payment_terms": "Monthly invoices due within 15 days of receipt. "
                             "Electronic funds transfer required for amounts exceeding $500,000.",
            "demurrage": "Demurrage charges of $3,500 per day shall apply for vessels detained beyond "
                         "the laytime allowance of 36 hours for loading and 36 hours for discharge.",
            "force_majeure": "Performance obligations are suspended during force majeure events. "
                             "Notice of force majeure must be provided within 48 hours of occurrence.",
            "termination": "Contract may be terminated by either party upon 60 days written notice. "
                           "Storage capacity must be vacated within 30 days of termination notice.",
            "liability_cap": "Terminal operator's liability for product losses is limited to the market "
                             "value of the lost product, not to exceed $2,000,000 per incident.",
            "confidentiality": "All inventory levels, throughput volumes, and pricing terms are deemed "
                                "confidential and shall not be disclosed to third parties without prior written consent.",
        }
    },
    {
        "id": "MAR-VC-2024-003",
        "type": "marine",
        "title": "Marine Voyage Charter Party",
        "vendor": "Atlantic Marine Carriers Ltd.",
        "commodity": "Liquefied Natural Gas (LNG)",
        "volume_commitment": "140,000 cubic meters per voyage",
        "rate": "$85,000 per day charter hire",
        "term_months": 6,
        "clauses": {
            "payment_terms": "Charter hire payable 15 days in advance. "
                             "Off-hire deductions calculated on a pro-rata daily basis.",
            "demurrage": "Laytime allowed: 36 running hours SHINC (Sundays and Holidays Included). "
                         "Demurrage rate: $42,000 per day, pro-rata. Dispatch: half demurrage rate.",
            "force_majeure": "In the event of war, hostilities, blockades, or acts of God preventing "
                             "the vessel from reaching the load or discharge port, the charter is cancelled "
                             "without liability to either party.",
            "termination": "Owner may withdraw vessel for non-payment of charter hire if payment remains "
                           "outstanding for more than 3 banking days after due date.",
            "liability_cap": "Carrier's liability limited to SDR 666.67 per package or SDR 2.00 per kilogram "
                             "of gross weight, whichever is higher, per Hague-Visby Rules.",
            "indemnification": "Charterer shall indemnify Owner against all consequences arising from "
                                "compliance with Charterer's instructions regarding the cargo.",
            "dispute_resolution": "This charter party shall be governed by English law. "
                                   "Disputes submitted to London Maritime Arbitrators Association (LMAA).",
        }
    },
    {
        "id": "RAIL-TA-2024-004",
        "type": "rail",
        "title": "Rail Transportation Agreement",
        "vendor": "Central Continental Railroad Corp.",
        "commodity": "Crude Oil — Unit Train Service",
        "volume_commitment": "10 unit trains per month minimum",
        "rate": "$2,850 per car per movement",
        "term_months": 18,
        "clauses": {
            "payment_terms": "Freight charges due and payable within 30 days of freight bill date. "
                             "Disputed charges must be submitted in writing within 180 days.",
            "force_majeure": "Carrier shall not be liable for delays caused by weather, derailments, "
                             "labor disputes, embargoes, government action, or other causes beyond carrier's control.",
            "termination": "Either party may terminate with 120 days written notice. "
                           "Volume commitments remain in effect through termination effective date.",
            "volume_commitment": "Shipper commits to tender a minimum of 10 unit trains (100 cars each) "
                                 "per calendar month. Shortfall penalty: 50% of applicable rate per car.",
            "liability_cap": "Carrier's maximum liability for loss or damage to lading is the actual value "
                             "of the commodity not to exceed $100,000 per car.",
            "dispute_resolution": "Disputes shall be resolved under the Surface Transportation Board "
                                   "regulations and applicable federal railroad law.",
        }
    },
    {
        "id": "TRUCK-RA-2024-005",
        "type": "trucking",
        "title": "Trucking and Freight Rate Agreement",
        "vendor": "Lone Star Logistics & Transport LLC",
        "commodity": "Refined Products — Bulk Liquid Transport",
        "volume_commitment": "150 loads per month estimated volume",
        "rate": "$4.25 per loaded mile; $1.10 per empty mile",
        "term_months": 12,
        "clauses": {
            "payment_terms": "Net 45 days from invoice date. "
                             "Quick pay option available at 2% discount for payment within 10 days.",
            "termination": "Either party may terminate this agreement with 30 days written notice. "
                           "Immediate termination permitted upon material safety violation.",
            "liability_cap": "Carrier liability for cargo loss or damage limited to actual invoice value "
                             "not to exceed $500,000 per occurrence. Carrier must maintain $1M cargo insurance.",
            "indemnification": "Carrier indemnifies Shipper against claims arising from carrier's negligence, "
                                "violations of law, or failure to comply with DOT safety regulations.",
            "confidentiality": "All rate information, lane volumes, and customer data are confidential. "
                                "Carrier agrees not to solicit Shipper's customers directly.",
            "dispute_resolution": "Disputes shall be governed by the laws of the State of Texas. "
                                   "Mandatory mediation before litigation.",
        }
    },
]


class ContractPDF(FPDF):
    def __init__(self, contract_id: str):
        super().__init__()
        self.contract_id = contract_id

    def header(self):
        self.set_font("Helvetica", "B", 10)
        self.set_text_color(100, 100, 100)
        self.cell(0, 8, f"CONFIDENTIAL — Contract ID: {self.contract_id}", align="R")
        self.ln(4)
        self.set_draw_color(200, 200, 200)
        self.line(10, self.get_y(), 200, self.get_y())
        self.ln(4)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(150, 150, 150)
        self.cell(0, 10, f"Page {self.page_no()} | CONFIDENTIAL | {self.contract_id}", align="C")


def generate_contract_pdf(contract: dict, output_dir: str) -> str:
    """Generate a realistic multi-page contract PDF."""
    effective = date.today()
    expiry = effective + timedelta(days=contract["term_months"] * 30)
    ref_num = "".join(random.choices(string.ascii_uppercase + string.digits, k=8))

    pdf = ContractPDF(contract_id=contract["id"])
    pdf.set_auto_page_break(auto=True, margin=20)
    pdf.add_page()

    # ---- Cover Page ----
    pdf.set_font("Helvetica", "B", 20)
    pdf.set_text_color(0, 0, 0)
    pdf.ln(10)
    pdf.cell(0, 12, contract["title"], align="C")
    pdf.ln(8)

    pdf.set_font("Helvetica", size=12)
    pdf.cell(0, 8, f"Contract ID: {contract['id']}", align="C")
    pdf.ln(6)
    pdf.cell(0, 8, f"Reference: {ref_num}", align="C")
    pdf.ln(6)
    pdf.cell(0, 8, f"Effective Date: {effective.strftime('%B %d, %Y')}", align="C")
    pdf.ln(6)
    pdf.cell(0, 8, f"Expiration Date: {expiry.strftime('%B %d, %Y')}", align="C")
    pdf.ln(14)

    pdf.set_font("Helvetica", "B", 11)
    pdf.cell(0, 8, "PARTIES TO THIS AGREEMENT", align="C")
    pdf.ln(6)
    pdf.set_font("Helvetica", size=10)
    pdf.cell(0, 6, "ExxonMobil Supply Chain Services LLC (\"Shipper\" / \"Buyer\")", align="C")
    pdf.ln(5)
    pdf.cell(0, 6, f"{contract['vendor']} (\"Carrier\" / \"Vendor\")", align="C")
    pdf.ln(14)

    # ---- Summary Section ----
    pdf.set_font("Helvetica", "B", 12)
    pdf.cell(0, 8, "CONTRACT SUMMARY")
    pdf.ln(6)

    summary_rows = [
        ("Commodity", contract["commodity"]),
        ("Volume Commitment", contract["volume_commitment"]),
        ("Rate / Pricing", contract["rate"]),
        ("Contract Term", f"{contract['term_months']} months"),
        ("Effective", effective.strftime("%B %d, %Y")),
        ("Expiration", expiry.strftime("%B %d, %Y")),
    ]

    pdf.set_font("Helvetica", size=10)
    for label, value in summary_rows:
        pdf.set_font("Helvetica", "B", 10)
        pdf.cell(55, 7, f"{label}:")
        pdf.set_font("Helvetica", size=10)
        pdf.cell(0, 7, value)
        pdf.ln(5)

    # ---- Terms and Conditions ----
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 14)
    pdf.cell(0, 10, "TERMS AND CONDITIONS")
    pdf.ln(8)

    section_num = 1
    for clause_name, clause_text in contract["clauses"].items():
        title = clause_name.replace("_", " ").title()
        pdf.set_font("Helvetica", "B", 11)
        pdf.cell(0, 8, f"Section {section_num}. {title}")
        pdf.ln(5)
        pdf.set_font("Helvetica", size=10)
        pdf.multi_cell(0, 6, clause_text)
        pdf.ln(5)
        section_num += 1

    # ---- Additional Boilerplate ----
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 14)
    pdf.cell(0, 10, "GENERAL PROVISIONS")
    pdf.ln(8)

    general_clauses = [
        ("Entire Agreement",
         "This Agreement constitutes the entire agreement between the parties with respect to the subject matter hereof "
         "and supersedes all prior and contemporaneous agreements, representations, warranties, and understandings."),
        ("Amendment",
         "No amendment, modification, or supplement to this Agreement shall be effective unless made in writing and "
         "signed by authorized representatives of both parties."),
        ("Severability",
         "If any provision of this Agreement is found invalid or unenforceable, the remaining provisions shall "
         "continue in full force and effect."),
        ("Waiver",
         "No waiver of any provision shall be effective unless in writing. A waiver of any breach shall not "
         "constitute a waiver of any subsequent breach."),
        ("Notices",
         "All notices required or permitted under this Agreement shall be in writing and delivered by certified mail, "
         "overnight courier, or email with confirmation to the addresses specified in Schedule A."),
        ("Assignment",
         "Neither party may assign this Agreement without the prior written consent of the other party, "
         "which shall not be unreasonably withheld."),
    ]

    for i, (title, text) in enumerate(general_clauses, start=section_num):
        pdf.set_font("Helvetica", "B", 11)
        pdf.cell(0, 8, f"Section {i}. {title}")
        pdf.ln(5)
        pdf.set_font("Helvetica", size=10)
        pdf.multi_cell(0, 6, text)
        pdf.ln(5)

    # ---- Signature Page ----
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 14)
    pdf.cell(0, 10, "SIGNATURE PAGE")
    pdf.ln(10)

    pdf.set_font("Helvetica", size=10)
    pdf.multi_cell(0, 6,
        "IN WITNESS WHEREOF, the parties have executed this Agreement as of the Effective Date first written above. "
        "Each signatory represents and warrants that they have the authority to bind their respective organization.")
    pdf.ln(14)

    for party in ["ExxonMobil Supply Chain Services LLC", contract["vendor"]]:
        pdf.set_font("Helvetica", "B", 10)
        pdf.cell(90, 6, party)
        pdf.ln(12)
        pdf.set_draw_color(0, 0, 0)
        pdf.line(10, pdf.get_y(), 100, pdf.get_y())
        pdf.ln(5)
        pdf.set_font("Helvetica", size=9)
        pdf.cell(90, 5, "Authorized Signature")
        pdf.ln(10)
        pdf.line(10, pdf.get_y(), 100, pdf.get_y())
        pdf.ln(5)
        pdf.cell(90, 5, "Printed Name and Title")
        pdf.ln(10)
        pdf.line(10, pdf.get_y(), 60, pdf.get_y())
        pdf.ln(5)
        pdf.cell(90, 5, "Date")
        pdf.ln(16)

    # Save
    os.makedirs(output_dir, exist_ok=True)
    path = os.path.join(output_dir, f"{contract['id']}.pdf")
    pdf.output(path)
    return path


def upload_to_s3(file_path: str, bucket: str, contract_type: str):
    s3 = boto3.client("s3")
    filename = os.path.basename(file_path)
    key = f"{contract_type}/{filename}"
    s3.upload_file(file_path, bucket, key)
    print(f"  Uploaded s3://{bucket}/{key}")


def main():
    parser = argparse.ArgumentParser(description="Generate synthetic supply chain contract PDFs")
    parser.add_argument("--upload", action="store_true", help="Upload PDFs to S3 Bronze bucket")
    parser.add_argument("--bucket", type=str, help="S3 Bronze bucket name")
    parser.add_argument("--output-dir", type=str, default=OUTPUT_DIR)
    args = parser.parse_args()

    if args.upload and not args.bucket:
        parser.error("--bucket required when --upload is set")

    print(f"Generating {len(CONTRACTS)} synthetic supply chain contracts...")
    for contract in CONTRACTS:
        path = generate_contract_pdf(contract, args.output_dir)
        print(f"  Generated: {path}")
        if args.upload:
            upload_to_s3(path, args.bucket, contract["type"])

    print(f"\nDone. {len(CONTRACTS)} contracts written to {args.output_dir}/")
    if args.upload:
        print("Contracts uploaded to Bronze — ETL pipeline will fire automatically.")


if __name__ == "__main__":
    main()
