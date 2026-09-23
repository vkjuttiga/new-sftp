variable "aws_region" {
  description = "Region of the Transfer Family server."
  type        = string
}

variable "server_id" {
  description = "Existing Transfer Family server ID (s-xxxxxxxxxxxxxxxxx)."
  type        = string
}

variable "bucket_name" {
  description = "Existing S3 bucket the SFTP users land in."
  type        = string
}

variable "role_arn" {
  description = "Existing IAM role Transfer Family assumes to reach S3. Shared by all users."
  type        = string
}

variable "users" {
  description = <<-EOT
    Map of SFTP users to create, keyed by user name.
      public_key_path       - file containing the user's OpenSSH public key
      home_directory_target - folder inside the bucket the user is locked into,
                              e.g. "acme/inbound". Defaults to the user name.
  EOT
  type = map(object({
    public_key_path       = string
    home_directory_target = optional(string)
  }))

  validation {
    condition = alltrue([
      for name in keys(var.users) : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9_@.-]{2,99}$", name))
    ])
    error_message = "User names must be 3-100 characters: letters, digits, _ @ . -  (and not start with a symbol)."
  }

  validation {
    condition = alltrue([
      for u in values(var.users) :
      u.home_directory_target == null ? true : !strcontains(u.home_directory_target, "..")
    ])
    error_message = "home_directory_target must not contain '..'."
  }
}
