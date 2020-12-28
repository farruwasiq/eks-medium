provider "aws" {
  region = "us-east-1"

}
resource "aws_vpc" "custom_vpc" {
  cidr_block = "10.0.0.0/16"
  # Your VPC must have DNS hostname and DNS resolution support. 
  # Otherwise, your worker nodes cannot register with your cluster. 
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name                                            = "${var.vpc_tag_name}-${var.environment}"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}
data "aws_availability_zones" "available" {}
### VPC Network Setup
# Create the private subnet
resource "aws_subnet" "private_subnet" {
  count      = var.subnet_count
  cidr_block = "10.0.1${count.index}.0/24"
  vpc_id     = "${aws_vpc.custom_vpc.id}"
  tags = {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"               = 1
  }
}
# Create the public subnet
resource "aws_subnet" "public_subnet" {
  count             = var.subnet_count
  vpc_id            = "${aws_vpc.custom_vpc.id}"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  cidr_block        = "10.0.2${count.index}.0/24"
  tags = {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/elb"                        = 1
  }
  map_public_ip_on_launch = true
}
# Create IGW for the public subnets
resource "aws_internet_gateway" "igw" {
  vpc_id = "${aws_vpc.custom_vpc.id}"
}
# Route the public subnet traffic through the IGW
resource "aws_route_table" "main" {
  vpc_id = "${aws_vpc.custom_vpc.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.igw.id}"
  }
  tags = {
    Name = "${var.route_table_tag_name}-${var.environment}"
  }
}
# Route table and subnet associations
resource "aws_route_table_association" "internet_access" {
  count          = length(var.availability_zones)
  subnet_id      = "${aws_subnet.public_subnet[count.index].id}"
  route_table_id = "${aws_route_table.main.id}"
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.eks_cluster_name}-cluster-${var.environment}"
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}
resource "aws_iam_role_policy_attachment" "aws_eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = "${aws_iam_role.eks_cluster.name}"
}
resource "aws_iam_role_policy_attachment" "aws_eks_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = "${aws_iam_role.eks_cluster.name}"
}
resource "aws_eks_cluster" "main" {
  name     = var.eks_cluster_name
  role_arn = "${aws_iam_role.eks_cluster.arn}"
  vpc_config {
    security_group_ids      = [aws_security_group.eks_cluster.id, aws_security_group.eks_nodes.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids              = concat(aws_subnet.private_subnet[*].id,aws_subnet.public_subnet[*].id)
  }
  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    "aws_iam_role_policy_attachment.aws_eks_cluster_policy",
    "aws_iam_role_policy_attachment.aws_eks_service_policy"
  ]
}
resource "aws_security_group" "eks_cluster" {
  name        = "cluster_sg"
  description = "Cluster communication with worker nodes"
  vpc_id      = aws_vpc.custom_vpc.id
  tags = {
    Name = "cluster_sg"
  }
}
resource "aws_security_group_rule" "cluster_inbound" {
  description              = "Allow worker nodes to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  to_port                  = 443
  type                     = "ingress"
}
resource "aws_security_group_rule" "cluster_outbound" {
  description              = "Allow cluster API Server to communicate with the worker nodes"
  from_port                = 1024
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  to_port                  = 65535
  type                     = "egress"
}
resource "aws_security_group" "eks_nodes" {
  name        = "eks_nodes_sg"
  description = "Security group for all nodes in the cluster"
  vpc_id      = aws_vpc.custom_vpc.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name                                            = "eks_nodes_sg"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "owned"
  }
}
resource "aws_security_group_rule" "nodes" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_nodes.id
  to_port                  = 65535
  type                     = "ingress"
}
resource "aws_security_group_rule" "nodes_inbound" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  to_port                  = 65535
  type                     = "ingress"
}
resource "aws_iam_role" "eks_nodes" {
  name               = "${var.eks_cluster_name}-worker-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.assume_workers.json
}
data "aws_iam_policy_document" "assume_workers" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy_attachment" "aws_eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}
resource "aws_iam_role_policy_attachment" "aws_eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}
resource "aws_iam_role_policy_attachment" "ec2_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}
resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  policy_arn = aws_iam_policy.cluster_autoscaler_policy.arn
  role       = aws_iam_role.eks_nodes.name
}
resource "aws_iam_policy" "cluster_autoscaler_policy" {
  name        = "ClusterAutoScaler"
  description = "Give the worker node running the Cluster Autoscaler access to required resources and actions"
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}
# Nodes in private subnets
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = concat(aws_subnet.private_subnet[*].id,aws_subnet.public_subnet[*].id)

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }
  tags = {
    Name = var.node_group_name
  }
  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.aws_eks_worker_node_policy,
    aws_iam_role_policy_attachment.aws_eks_cni_policy,
    aws_iam_role_policy_attachment.ec2_read_only,
  ]
}
# Nodes in public subnet
resource "aws_eks_node_group" "public" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.node_group_name}-public"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.public_subnet[0].id, aws_subnet.public_subnet[1].id]
  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }
  tags = {
    Name = "${var.node_group_name}-public"
  }
  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.aws_eks_worker_node_policy,
    aws_iam_role_policy_attachment.aws_eks_cni_policy,
    aws_iam_role_policy_attachment.ec2_read_only,
  ]
}
provider "helm" {
  version = "1.3.1"
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority.0.data)
#    token                  = data.aws_eks_cluster_auth.cluster.token
    load_config_file       = false
  }
}

resource "helm_release" "ingress" {
  name       = "ingress"
  chart      = "aws-alb-ingress-controller"
  repository = "https://charts.helm.sh/incubator/"
  version    = "1.0.2"

  set {
    name  = "autoDiscoverAwsRegion"
    value = "true"
  }
  set {
    name  = "autoDiscoverAwsVpcID"
    value = "true"
  }
  set {
    name  = "clusterName"
    value = var.eks_cluster_name
  }
}