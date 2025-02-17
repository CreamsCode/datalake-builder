provider "aws" {
  region = "us-east-1"
}

data "aws_ssm_parameter" "vpc_id" {
  name = "/shared/vpc/id"
}

data "aws_ssm_parameter" "igw_id" {
  name = "/shared/vpc/igw_id"
}

data "aws_ssm_parameter" "route_table_id" {
  name = "/shared/vpc/route_table_id"
}

variable "sqs_queue_url" {
  description = "URL of the SQS Queue"
  type        = string
}

resource "aws_subnet" "mongodb_subnet" {
  vpc_id                  = data.aws_ssm_parameter.vpc_id.value
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  tags = {
    Name = "MongoDB Subnet"
  }
}

resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.mongodb_subnet.id
  route_table_id = data.aws_ssm_parameter.route_table_id.value
}

resource "aws_security_group" "mongodb_cluster" {
  vpc_id = data.aws_ssm_parameter.vpc_id.value
  tags = {
    Name = "MongoDBSecurityGroup"
  }

  ingress {
    description = "MongoDB access"
    from_port   = 27017
    to_port     = 27019
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "listener_security" {
  vpc_id = data.aws_ssm_parameter.vpc_id.value
  tags = {
    Name = "ListenerSecurityGroup"
  }

  ingress {
    description = "SSH Access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_sqs_queue" "scraper_queue" {
  name = "scraper-queue"
}

resource "aws_instance" "mongodb_server" {
  ami           = "ami-05576a079321f21f8"
  instance_type = "t2.micro"
  key_name      = "vockey"
  subnet_id     = aws_subnet.mongodb_subnet.id
  vpc_security_group_ids = [aws_security_group.mongodb_cluster.id]
  iam_instance_profile   = "EMR_EC2_DefaultRole"
  tags = {
    Name = "MongoDB-Server"
  }
  user_data = <<-EOF
    #!/bin/bash
    echo '[mongodb-org-8.0]' | sudo tee /etc/yum.repos.d/mongodb-org-8.0.repo
    echo 'name=MongoDB Repository' | sudo tee -a /etc/yum.repos.d/mongodb-org-8.0.repo
    echo 'baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/8.0/x86_64/' | sudo tee -a /etc/yum.repos.d/mongodb-org-8.0.repo
    echo 'gpgcheck=1' | sudo tee -a /etc/yum.repos.d/mongodb-org-8.0.repo
    echo 'enabled=1' | sudo tee -a /etc/yum.repos.d/mongodb-org-8.0.repo
    echo 'gpgkey=https://pgp.mongodb.com/server-8.0.asc' | sudo tee -a /etc/yum.repos.d/mongodb-org-8.0.repo
    dnf install -y mongodb-org mongodb-mongosh-shared-openssl3 openssl mongodb-org-database-tools-extra mongodb-database-tools mongodb-org-tools mongodb-org-server mongodb-org-mongos mongodb-org-database jq
    sudo sed -i 's/^  bindIp: .*/  bindIp: 0.0.0.0/' /etc/mongod.conf
    sudo rm -f /tmp/mongodb-27017.sock
    sudo chown -R mongod:mongod /var/lib/mongo
    sudo chown -R mongod:mongod /var/log/mongodb
    sudo chmod 700 /var/lib/mongo
    sudo chmod 700 /var/log/mongodb
    sudo systemctl enable mongod
    sudo systemctl start mongod
  EOF
}

resource "aws_instance" "listener" {
  ami           = "ami-05576a079321f21f8"
  instance_type = "t2.micro"
  key_name      = "vockey"
  subnet_id     = aws_subnet.mongodb_subnet.id
  vpc_security_group_ids = [aws_security_group.listener_security.id]
  iam_instance_profile   = "EMR_EC2_DefaultRole"
  tags = {
    Name = "Listener"
  }
  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y git python3-pip aws-cli
    export SQS_QUEUE_URL="${var.sqs_queue_url}"
    export MONGODB_IP=$(aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=MongoDB-Server" \
      --query "Reservations[*].Instances[*].PublicIpAddress" \
      --output text \
      --region us-east-1)
    sudo echo "MONGODB_IP=$MONGODB_IP"
    sudo echo "SQS_QUEUE_URL=$SQS_QUEUE_URL"
    sudo git clone https://github.com/CreamsCode/datalake-builder.git /home/ec2-user/datalake
    cd /home/ec2-user/datalake
    sudo pip3 install -r requirements.txt
    sudo python3 main.py --queue_url ${var.sqs_queue_url} --ip ${aws_instance.mongodb_server.public_ip}
  EOF
}

output "mongodb_server_public_ip" {
  value       = aws_instance.mongodb_server.public_ip
  description = "Public IP of the MongoDB server"
}

output "listener_public_ip" {
  value       = aws_instance.listener.public_ip
  description = "Public IP of the Listener instance"
}

resource "aws_ssm_parameter" "mongodb_ip" {
  name  = "mongodb_ip"
  type  = "String"
  value = aws_instance.mongodb_server.public_ip
  overwrite = true
}

resource "aws_ssm_parameter" "listener_ip" {
  name  = "listener_ip"
  type  = "String"
  value = aws_instance.listener.public_ip
  overwrite = true
}

