# Provider configuration for DR module

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0.0"
      configuration_aliases = [
        aws.dr,
        aws.primary
      ]
    }
  }
}
