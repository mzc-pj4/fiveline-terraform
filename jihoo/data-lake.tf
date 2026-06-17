# ── S3 Data Lake Bucket ─────────────────────────────────────────────────────

resource "aws_s3_bucket" "data_lake" {
  bucket = "mzc-pj4-${local.owner}-data-lake-${local.env}"

  tags = {
    Service = "data-lake"
    Name    = "mzc-pj4-${local.owner}-data-lake-${local.env}"
  }
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
