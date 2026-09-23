output "users" {
  description = "Created users and the S3 location each one is locked into."
  value = {
    for name, u in local.users : name => "s3://${var.bucket_name}/${u.prefix}/"
  }
}
