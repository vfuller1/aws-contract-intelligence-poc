terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "aws-contract-intel-tfstate"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "aws-contract-intel-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-contract-intelligence"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = "victor-fuller"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name prefix for resource naming"
  type        = string
  default     = "contract-intel"
}

variable "enable_rag" {
  description = "Feature flag — enables Bedrock Knowledge Base + OpenSearch (~$0.96/hr)"
  type        = bool
  default     = true # set to false to destroy OpenSearch and save ~$0.96/hr
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  prefix = "${var.project}-${var.environment}"
}
