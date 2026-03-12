# S3 bucket 
resource "aws_s3_bucket" "data_bucket" {
  bucket = "ds5220-sophie-kim-sensor-data"
}

# SNS topic 
resource "aws_sns_topic" "sensor_topic" {
  name = "ds5220-dp1-topic"
}

# SNS topic policy
resource "aws_sns_topic_policy" "default" {
  arn = aws_sns_topic.sensor_topic.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      # says that S3 is allowed to talk to SNS topic 
      Principal = { Service = "s3.amazonaws.com" }
      # says that S3 is allowed to send aka publish messages  
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.sensor_topic.arn
      # ensures that only my bucket can send messages to SNS topic 
      Condition = {
        ArnLike = { "aws:SourceArn" = aws_s3_bucket.data_bucket.arn }
      }
    }]
  })
}

# S3 notification -- linking bucket to SNS topic 
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.data_bucket.id

  topic {
    topic_arn     = aws_sns_topic.sensor_topic.arn
    # every time a new file is created, S3 will do something 
    events        = ["s3:ObjectCreated:*"]
    # action happens when csv file uploaded to raw folder 
    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }
  # this is important bc it won't set up the notif until SNS topic policy is ready so S3 has the permissions it needs
  depends_on = [aws_sns_topic_policy.default]
}

#  EC2 instance
resource "aws_instance" "app_server" {
  ami           = "ami-04b70fa74e45c3917"
  instance_type = "t3.micro"
  key_name      = "ds5220awssshkey"
  
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  
  # runs once when the server boots up and saves the bucket name var into environment so py file can find 
  user_data = <<-EOF
              #!/bin/bash
              echo "BUCKET_NAME=${aws_s3_bucket.data_bucket.id}" >> /etc/environment
              export BUCKET_NAME=${aws_s3_bucket.data_bucket.id}
              EOF

  tags = { Name = "DS5220-Sophie-Kim" }
}

# elastic IP
resource "aws_eip" "app_ip" {
  instance = aws_instance.app_server.id
}

# security group
resource "aws_security_group" "app_sg" {
  name        = "ds5220-app-sg"
  description = "Allow SSH and FastAPI traffic"

  # SSH access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] 
  }

  # FastAPI access so SNS can send HTTP notifs to app 
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# roles
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ds5220-ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_iam_role" "ec2_role" {
  name = "ds5220-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
    # so EC2 instance can assume role 
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}