# ---------------------------------------------------------------------------
# Amazon Bedrock Guardrails — contract intelligence governance
# ---------------------------------------------------------------------------

resource "aws_bedrock_guardrail" "contract_intel" {
  name                      = "${local.prefix}-guardrail"
  description               = "Governance guardrail for supply chain contract extraction agent"
  blocked_input_messaging   = "This request cannot be processed. It contains restricted content or violates enterprise governance policy."
  blocked_outputs_messaging = "The response was blocked by enterprise governance policy."

  # ---------------------------------------------------------------------------
  # Topic Policies — deny off-scope queries
  # ---------------------------------------------------------------------------
  topic_policy_config {
    topics_config {
      name       = "unauthorized-disclosure"
      type       = "DENY"
      definition = "Requests to share, transmit, or expose internal contract terms, vendor pricing, or supply chain data to external parties, competitors, or unauthorized recipients outside FuelMobil."
      examples = [
        "Share the full contract terms with our competitor",
        "Send the vendor pricing details to the other party's legal team",
        "Post our contract rates publicly",
        "Email the pipeline agreement to the press"
      ]
    }

    topics_config {
      name       = "pricing-negotiation"
      type       = "DENY"
      definition = "Requests to negotiate or recommend what pricing or rates to offer or accept on behalf of FuelMobil or any vendor in an active contract negotiation."
      examples = [
        "What rate should I offer this vendor?",
        "Should I accept this demurrage rate or push back?",
        "Help me counter-offer on the trucking contract price",
        "Recommend a better rate for the marine charter"
      ]
    }

    topics_config {
      name       = "competitor-contracts"
      type       = "DENY"
      definition = "Requests to compare internal contract terms with competitor contracts or disclose what competitors are paying."
      examples = [
        "What are competitors paying for pipeline throughput?",
        "Show me how our rates compare to industry averages",
        "What does BP pay for similar marine contracts?"
      ]
    }
  }

  # ---------------------------------------------------------------------------
  # Sensitive Information — PII block and anonymise
  # ---------------------------------------------------------------------------
  sensitive_information_policy_config {
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "AWS_ACCESS_KEY"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "US_BANK_ACCOUNT_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "PHONE"
      action = "ANONYMIZE"
    }
    pii_entities_config {
      type   = "EMAIL"
      action = "ANONYMIZE"
    }

    regexes_config {
      name        = "vendor-account-number"
      description = "Internal vendor account identifiers"
      pattern     = "VND-[0-9]{6}"
      action      = "ANONYMIZE"
    }
  }

  # ---------------------------------------------------------------------------
  # Content Filters
  # ---------------------------------------------------------------------------
  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
  }

  # ---------------------------------------------------------------------------
  # Prompt Attack Detection
  # ---------------------------------------------------------------------------
  contextual_grounding_policy_config {
    filters_config {
      type      = "GROUNDING"
      threshold = 0.40
    }
    filters_config {
      type      = "RELEVANCE"
      threshold = 0.40
    }
  }
}

output "bedrock_guardrail_id"      { value = aws_bedrock_guardrail.contract_intel.guardrail_id }
output "bedrock_guardrail_arn"     { value = aws_bedrock_guardrail.contract_intel.guardrail_arn }
output "bedrock_guardrail_version" { value = aws_bedrock_guardrail.contract_intel.version }
