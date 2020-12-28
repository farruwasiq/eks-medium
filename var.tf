variable "vpc_cidr_block" {
  type    = string
  default = "10.212.210.0/24"

}
variable "environment" {
  type    = string
  default = "dev"
}
variable "eks_cluster_name" {
  default = "medium"

}
variable "vpc_tag_name" {

  type    = string
  default = "dev-vpc"

}

variable "availability_zones" {
  type    = list
  default = ["us-east-1a", "us-east-1b"]

}
variable "subnet_count" {
    type = string
    default="2"
  
}
variable "public_subnet_cidr_block" {
  type    = string
  default = "10.212.210.0/27"

}
variable "public_subnet_cidr_blocks" {
  type    = list
  default = ["10.212.210.0/27", "10.212.210.32/27"]

}
variable "region" {
  default = "us-east-1"

}
variable "private_subnet_cidr_block" {
  type    = string
  default = "10.212.210.64/27"

}
variable "private_subnet_cidr_blocks" {
  type    = list
  default = ["10.212.210.64/27", "10.212.210.96/27"]

}
variable "route_table_tag_name" {
  type    = string
  default = "public-rt"

}
variable "cluster_sg_name" {
  type    = string
  default = "cluster-sg"

}
variable "node_group_name" {
  type    = string
  default = "worker-nodes-group"

}