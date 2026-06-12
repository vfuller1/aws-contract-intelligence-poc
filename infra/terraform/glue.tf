# ---------------------------------------------------------------------------
# AWS Glue — Data Catalog + Crawler over Gold S3 layer
# ---------------------------------------------------------------------------

# IAM role for Glue crawler
resource "aws_iam_role" "glue_crawler" {
  name = "${local.prefix}-glue-crawler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_kms" {
  name = "${local.prefix}-glue-s3-kms-policy"
  role = aws_iam_role.glue_crawler.id

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
        Sid      = "KMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

# Glue Database
resource "aws_glue_catalog_database" "contracts" {
  name        = "${replace(local.prefix, "-", "_")}_contracts"
  description = "Supply chain contract intelligence — Gold layer catalog"
}

# Glue Crawler — discovers schema from Gold S3 layer
resource "aws_glue_crawler" "gold_contracts" {
  name          = "${local.prefix}-gold-crawler"
  role          = aws_iam_role.glue_crawler.arn
  database_name = aws_glue_catalog_database.contracts.name
  description   = "Crawls Gold S3 layer to catalog extracted contract data"

  s3_target {
    path = "s3://${aws_s3_bucket.lakehouse["gold"].bucket}/contracts/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
      Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
  })

  # Run on demand — triggered by ETL Silver→Gold completion
  # schedule = "cron(0 6 * * ? *)"  # Uncomment for daily scheduled crawl
}

output "glue_database_name"  { value = aws_glue_catalog_database.contracts.name }
output "glue_crawler_name"   { value = aws_glue_crawler.gold_contracts.name }
