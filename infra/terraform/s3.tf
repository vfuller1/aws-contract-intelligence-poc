# ---------------------------------------------------------------------------
# S3 — Bronze / Silver / Gold medallion lakehouse
# ---------------------------------------------------------------------------

locals {
  buckets = {
    bronze = "${local.prefix}-bronze"
    silver = "${local.prefix}-silver"
    gold   = "${local.prefix}-gold"
    athena = "${local.prefix}-athena-results"
  }
}

resource "aws_s3_bucket" "lakehouse" {
  for_each = local.buckets
  bucket   = each.value
}

resource "aws_s3_bucket_versioning" "lakehouse" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.lakehouse[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lakehouse" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.lakehouse[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "lakehouse" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.lakehouse[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tls_only" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.lakehouse[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.lakehouse[each.key].arn,
        "${aws_s3_bucket.lakehouse[each.key].arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# S3 event notification — Bronze bucket triggers Lambda router on PDF upload
resource "aws_s3_bucket_notification" "bronze_trigger" {
  bucket = aws_s3_bucket.lakehouse["bronze"].id

  lambda_function {
    lambda_function_arn = aws_lambda_function.router.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".pdf"
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

# Outputs for use in scripts
output "bronze_bucket" { value = aws_s3_bucket.lakehouse["bronze"].bucket }
output "silver_bucket" { value = aws_s3_bucket.lakehouse["silver"].bucket }
output "gold_bucket"   { value = aws_s3_bucket.lakehouse["gold"].bucket }
output "athena_bucket" { value = aws_s3_bucket.lakehouse["athena"].bucket }
