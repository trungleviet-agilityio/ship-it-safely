locals {
  default_tags = {
    Project   = "ship-it-safely"
    Env       = var.env
    ManagedBy = "terraform"
  }
}
