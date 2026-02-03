terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# ===== S3 BUCKET FOR RAW DATA =====
resource "aws_s3_bucket" "data_lake" {
  bucket        = "ny-taxi-data-lake-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "data_lake_versioning" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ===== S3 BUCKET FOR ATHENA QUERY RESULTS =====
resource "aws_s3_bucket" "athena_results" {
  bucket        = "ny-taxi-athena-results-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

# ===== ATHENA DATABASE =====
resource "aws_athena_database" "taxi_database" {
  name   = "ny_taxi"
  bucket = aws_s3_bucket.athena_results.id

  properties = {
    "classification" = "csv"
  }
}

# ===== ATHENA WORKGROUP =====
resource "aws_athena_workgroup" "taxi_workgroup" {
  name = "ny-taxi-workgroup"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"
    }
  }
}

# ===== OUTPUTS =====
output "s3_data_lake_bucket" {
  value       = aws_s3_bucket.data_lake.id
  description = "S3 bucket for raw taxi data"
}

output "s3_athena_results_bucket" {
  value       = aws_s3_bucket.athena_results.id
  description = "S3 bucket for Athena query results"
}

output "athena_database_name" {
  value       = aws_athena_database.taxi_database.name
  description = "Athena database name"
}

# output "athena_workgroup_name" {
#   value       = aws_athena_workgroup.taxi_workgroup.name
#   description = "Athena workgroup name"
# }

output "aws_account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "AWS Account ID"
}

output "aws_region" {
  value       = var.aws_region
  description = "AWS Region"
}