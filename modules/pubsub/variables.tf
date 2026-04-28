# modules/pubsub/variables.tf

variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "labels" {
  description = "Labels to apply to the topics."
  type        = map(string)
  default     = {}
}
