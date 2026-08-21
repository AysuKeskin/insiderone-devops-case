# --- EC2 instance profile: SSM only, no SSH ---------------------------------
data "aws_iam_policy_document" "ec2_ssm_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_ssm" {
  name               = "ec2-ssm-${var.github_repo}"
  assume_role_policy = data.aws_iam_policy_document.ec2_ssm_trust.json

  # Renaming replaces this resource while it is still attached to the running
  # instance; without create_before_destroy Terraform deletes the old one first
  # and AWS rejects it with DependencyViolation.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "ec2-ssm-${var.github_repo}"
  role = aws_iam_role.ec2_ssm.name

  # Renaming replaces this resource while it is still attached to the running
  # instance; without create_before_destroy Terraform deletes the old one first
  # and AWS rejects it with DependencyViolation.
  lifecycle {
    create_before_destroy = true
  }
}

# --- security group: only 80/443 in, all out, NO SSH ------------------------
resource "aws_security_group" "ec2" {
  name        = "${var.github_repo}-ec2"
  description = "Inbound HTTP/HTTPS for the demo app. No SSH - access is via SSM Session Manager."

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Renaming replaces this resource while it is still attached to the running
  # instance; without create_before_destroy Terraform deletes the old one first
  # and AWS rejects it with DependencyViolation.
  lifecycle {
    create_before_destroy = true
  }
}

# --- EC2 instance -----------------------------------------------------------
resource "aws_instance" "app" {
  # Amazon Linux 2023 (x86_64), SSM agent preinstalled. Pinned deliberately:
  # this host carries a stateful single-node minikube cluster and a live
  # Let's Encrypt cert, so a floating "most recent" lookup would replace the
  # instance -- and wipe both -- on an otherwise unrelated apply.
  ami                    = "ami-048a4ba4502b46dd7"
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    github_owner = var.github_owner
    github_repo  = var.github_repo
  })

  tags = {
    Name = "${var.github_repo}-app"
  }

  # user_data only ever runs on first boot, but the provider stops and starts
  # the instance to change the attribute. This host is already bootstrapped and
  # its minikube cluster does not survive reboots cleanly, so drift here is
  # ignored. A replacement still gets the current script.
  lifecycle {
    ignore_changes = [user_data]
  }
}

# --- Elastic IP -------------------------------------------------------------
resource "aws_eip" "app" {
  domain = "vpc"

  tags = {
    Name = "${var.github_repo}-app"
  }
}

resource "aws_eip_association" "app" {
  instance_id   = aws_instance.app.id
  allocation_id = aws_eip.app.id
}
