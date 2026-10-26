resource "aws_ecr_repository" "app" {
  name                 = local.names.ecr_repository
  image_tag_mutability = "IMMUTABLE"
  # Removed with the stack: the lab is torn down after every session.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# One rule only. No "expire untagged" rule: buildx index children and attestations can be untagged, and
# expiring them could break an image pinned by digest (ADR 0004, E10).
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${var.ecr_keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_keep_images
      }
      action = { type = "expire" }
    }]
  })
}
