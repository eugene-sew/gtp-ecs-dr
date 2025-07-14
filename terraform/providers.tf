# Provider configuration file
# This defines both the primary region provider and DR region provider

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region
}
