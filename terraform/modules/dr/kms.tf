# KMS key for DR region encryption
resource "aws_kms_key" "dr_rds_key" {
  count                    = var.enable_db_replica ? 1 : 0
  provider                 = aws.dr
  description              = "KMS key for DR RDS encryption in ${data.aws_region.dr.id}"
  deletion_window_in_days  = 7
  enable_key_rotation      = true
  
  tags = {
    Name        = "${var.environment}-dr-${var.app_name}-rds-key"
    Environment = "${var.environment}-dr"
  }
}

resource "aws_kms_alias" "dr_rds_key_alias" {
  count         = var.enable_db_replica ? 1 : 0
  provider      = aws.dr
  name          = "alias/${var.environment}-dr-${var.app_name}-rds-key"
  target_key_id = aws_kms_key.dr_rds_key[0].key_id
}
