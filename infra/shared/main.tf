################################################################################
# SHARED SERVICES (would be a separate security / shared-services account)
#
#  1. KMS key for secrets            customer-managed, rotation on, narrow key policy
#  2. Secret CONTAINERS, not values  Terraform owns name/key/policy/tags; the VALUE is set once,
#                                    out-of-band, by the owner -> never in Git, plan output or state
#  3. Resource policy                explicit DENY on reading the value for everyone except the
#                                    External Secrets roles of the clusters that need it (admins too)
#  4. Model registry bucket          versioned, immutable (no deletes), only the ingest role writes,
#                                    every environment's serving role reads the SAME artifact
################################################################################

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  role_arn   = "arn:aws:iam::${local.account_id}:role"

  # Only these roles (created per cluster by infra/modules/eks-spoke) may read secret values.
  # Pattern-based so the shared stack has no dependency on environments (applied first).
  secret_reader_roles = ["${local.role_arn}/${var.cluster_name_pattern}-external-secrets"]
  model_writer_roles  = ["${local.role_arn}/${var.cluster_name_pattern}-model-ingest"]

  # Secrets this stack manages. Values are NOT here, only metadata.
  secrets = {
    "hf-token" = {
      description = "Hugging Face read token (org service account) used ONLY by the model ingest job"
      rotation    = "90d-manual" # HF has no rotation API: calendar reminder + runbook
    }
  }

  model_registry_bucket = "${var.name_prefix}-model-registry-${local.account_id}"
}

################################################################################
# 1. KMS key for Secrets Manager
################################################################################
data "aws_iam_policy_document" "secrets_key" {
  # Key administration stays with the account (IAM policies decide which admins)
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
  # Workload roles may decrypt ONLY when the call comes through Secrets Manager
  statement {
    sid       = "DecryptViaSecretsManagerForSecretReaders"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = local.secret_reader_roles
    }
  }
}

resource "aws_kms_key" "secrets" {
  description             = "${var.name_prefix} Secrets Manager key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.secrets_key.json
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

################################################################################
# 2 + 3. Secret containers + resource policies (no values)
################################################################################
resource "aws_secretsmanager_secret" "this" {
  for_each                = local.secrets
  name                    = "${var.name_prefix}/${each.key}"
  description             = each.value.description
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 7
  tags = {
    Owner    = var.secret_owner
    Rotation = each.value.rotation
  }
}

data "aws_iam_policy_document" "secret" {
  for_each = local.secrets

  # Deny reading the VALUE to every principal that is not an approved workload role.
  # An explicit deny beats any Allow, so this also stops account admins and SSO users.
  statement {
    sid       = "DenyValueReadExceptWorkloads"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.secret_reader_roles
    }
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  for_each            = local.secrets
  secret_arn          = aws_secretsmanager_secret.this[each.key].arn
  policy              = data.aws_iam_policy_document.secret[each.key].json
  block_public_policy = true
}

################################################################################
# 4. Model registry: one immutable store, every environment reads the same artifact
################################################################################
resource "aws_s3_bucket" "models" {
  bucket        = local.model_registry_bucket
  force_destroy = var.allow_force_destroy
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_ownership_controls" "models" {
  bucket = aws_s3_bucket.models.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Open-weight models are public data: SSE-S3 is enough and keeps reads simple.
# (Proprietary/fine-tuned weights: switch to SSE-KMS with its own key + key policy.)
resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    id     = "clean-up"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 2 }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

data "aws_iam_policy_document" "models" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.models.arn, "${aws_s3_bucket.models.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  # Only the ingest role writes. Everyone else (admins, serving, training) is read-only here.
  statement {
    sid       = "OnlyIngestWrites"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.models.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.model_writer_roles
    }
  }
  # Published artifacts are immutable: nobody deletes objects or versions, admins included.
  # (Teardown: set allow_force_destroy = true and apply; destroy removes this policy first.)
  statement {
    sid       = "ArtifactsAreImmutable"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.models.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "models" {
  bucket     = aws_s3_bucket.models.id
  policy     = data.aws_iam_policy_document.models.json
  depends_on = [aws_s3_bucket_public_access_block.models]
}
