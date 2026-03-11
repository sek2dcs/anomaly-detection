# 1. S3 Bucket with unique name
resource "aws_s3_bucket" "data_bucket" {
  bucket = "ds5220-sophie-kim-sensor-data"
  force_destroy = true # Allows deletion even if files exist
}

# 2. SNS Topic for notifications
resource "aws_sns_topic" "sensor_topic" {
  name = "ds5220-dp1-topic"
}

# 3. SNS Topic Policy (Allows S3 to Publish)
resource "aws_sns_topic_policy" "default" {
  arn = aws_sns_topic.sensor_topic.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.sensor_topic.arn
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.data_bucket.arn }
      }
    }]
  })
}

# 4. S3 Notification (Depends on Policy being ready)
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.data_bucket.id

  topic {
    topic_arn     = aws_sns_topic.sensor_topic.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sns_topic_policy.default]
}

# 5. EC2 Instance
resource "aws_instance" "app_server" {
  ami           = "ami-04b70fa74e45c3917" # Ubuntu 24.04 in us-east-1
  instance_type = "t3.micro"
  key_name      = "ds5220awssshkey"
  
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "BUCKET_NAME=${aws_s3_bucket.data_bucket.id}" >> /etc/environment
              export BUCKET_NAME=${aws_s3_bucket.data_bucket.id}
              # Add git clone and pip install commands here...
              EOF

  tags = { Name = "DS5220-Sophie-Kim" }
}

# 6. Elastic IP
resource "aws_eip" "app_ip" {
  instance = aws_instance.app_server.id
}

resource "aws_security_group" "app_sg" {
  name        = "ds5220-app-sg"
  description = "Allow SSH and FastAPI traffic"

  # SSH Access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # For production, use your specific IP
  }

  # FastAPI Access
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic (so EC2 can download python packages)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ds5220-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name # This assumes you have an 'aws_iam_role.ec2_role' defined
}

resource "aws_iam_role" "ec2_role" {
  name = "ds5220-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}