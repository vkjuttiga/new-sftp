locals {
  users = {
    for name, u in var.users : name => {
      public_key = trimspace(file(u.public_key_path))
      prefix     = trim(coalesce(u.home_directory_target, name), "/")
    }
  }
}

resource "aws_transfer_user" "this" {
  for_each = local.users

  server_id = var.server_id
  user_name = each.key
  role      = var.role_arn

  # Logical root "/" maps to s3://<bucket>/<prefix>; permissions come
  # entirely from var.role_arn (shared by all users, no per-user policy).
  home_directory_type = "LOGICAL"
  home_directory_mappings {
    entry  = "/"
    target = "/${var.bucket_name}/${each.value.prefix}"
  }

  tags = {
    Name = each.key
  }
}

resource "aws_transfer_ssh_key" "this" {
  for_each = local.users

  server_id = var.server_id
  user_name = aws_transfer_user.this[each.key].user_name
  body      = each.value.public_key
}
