# ---------------------------------------------------------------------------
# Bedrock Knowledge Base + OpenSearch Serverless
# Feature-flagged via var.enable_rag — ~$0.96/hr when active
# ---------------------------------------------------------------------------

# IAM role for Bedrock KB
resource "aws_iam_role" "bedrock_kb" {
  count = var.enable_rag ? 1 : 0
  name  = "${local.prefix}-bedrock-kb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_kb_policy" {
  count = var.enable_rag ? 1 : 0
  name  = "${local.prefix}-bedrock-kb-policy"
  role  = aws_iam_role.bedrock_kb[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GoldBucketRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.lakehouse["gold"].arn,
          "${aws_s3_bucket.lakehouse["gold"].arn}/*"
        ]
      },
      {
        Sid      = "OpenSearchAccess"
        Effect   = "Allow"
        Action   = ["aoss:APIAccessAll"]
        Resource = "*"
      },
      {
        Sid      = "BedrockEmbeddings"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
      }
    ]
  })
}

# OpenSearch Serverless — vector store for contract embeddings
resource "aws_opensearchserverless_collection" "contracts" {
  count = var.enable_rag ? 1 : 0
  name  = "${local.prefix}-vectors"
  type  = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
    aws_opensearchserverless_access_policy.data
  ]
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  count       = var.enable_rag ? 1 : 0
  name        = "${local.prefix}-enc"
  type        = "encryption"
  description = "Encryption policy for contract vectors collection"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.prefix}-vectors"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  count       = var.enable_rag ? 1 : 0
  name        = "${local.prefix}-net"
  type        = "network"
  description = "Network policy — private VPC access only"

  policy = jsonencode([{
    Rules = [
      { ResourceType = "collection", Resource = ["collection/${local.prefix}-vectors"] },
      { ResourceType = "dashboard",  Resource = ["collection/${local.prefix}-vectors"] }
    ]
    AllowFromPublic = false
  }])
}

resource "aws_opensearchserverless_access_policy" "data" {
  count       = var.enable_rag ? 1 : 0
  name        = "${local.prefix}-access"
  type        = "data"
  description = "Data access policy for Bedrock KB role"

  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${local.prefix}-vectors/*"]
        Permission   = ["aoss:CreateIndex", "aoss:DeleteIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.prefix}-vectors"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:DeleteCollectionItems", "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"]
      }
    ]
    Principal = [
      var.enable_rag ? aws_iam_role.bedrock_kb[0].arn : "",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
    ]
  }])
}

# Bedrock Knowledge Base
resource "aws_bedrockagent_knowledge_base" "contracts" {
  count    = var.enable_rag ? 1 : 0
  name     = "${local.prefix}-knowledge-base"
  role_arn = aws_iam_role.bedrock_kb[0].arn

  knowledge_base_configuration {
    type = "VECTOR"
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"
    }
  }

  storage_configuration {
    type = "OPENSEARCH_SERVERLESS"
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.contracts[0].arn
      vector_index_name = "contract-chunks"
      field_mapping {
        vector_field   = "contract-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
  }
}

# Bedrock KB Data Source — points to Gold S3 layer
resource "aws_bedrockagent_data_source" "gold_contracts" {
  count            = var.enable_rag ? 1 : 0
  knowledge_base_id = aws_bedrockagent_knowledge_base.contracts[0].id
  name             = "${local.prefix}-gold-datasource"

  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn              = aws_s3_bucket.lakehouse["gold"].arn
      inclusion_prefixes      = ["contracts/"]
    }
  }

  vector_ingestion_configuration {
    chunking_configuration {
      chunking_strategy = "FIXED_SIZE"
      fixed_size_chunking_configuration {
        max_tokens         = 500
        overlap_percentage = 10
      }
    }
  }
}

output "knowledge_base_id" {
  value = var.enable_rag ? aws_bedrockagent_knowledge_base.contracts[0].id : "RAG disabled — set enable_rag=true"
}

output "opensearch_collection_endpoint" {
  value = var.enable_rag ? aws_opensearchserverless_collection.contracts[0].collection_endpoint : "RAG disabled"
}
