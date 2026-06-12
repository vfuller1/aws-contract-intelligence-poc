# ---------------------------------------------------------------------------
# DynamoDB — contract processing state + Terraform remote state lock
# ---------------------------------------------------------------------------

# Contract processing state table
resource "aws_dynamodb_table" "contract_state" {
  name         = "${local.prefix}-contract-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "contract_id"
  range_key    = "processing_stage"

  attribute {
    name = "contract_id"
    type = "S"
  }

  attribute {
    name = "processing_stage"
    type = "S"
  }

  attribute {
    name = "contract_type"
    type = "S"
  }

  global_secondary_index {
    name            = "ContractTypeIndex"
    hash_key        = "contract_type"
    range_key       = "processing_stage"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "${local.prefix}-contract-state"
  }
}

# Terraform state lock table
resource "aws_dynamodb_table" "tf_state_lock" {
  name         = "aws-contract-intel-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "dynamodb_contract_state_table" {
  value = aws_dynamodb_table.contract_state.name
}
