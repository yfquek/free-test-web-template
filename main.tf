# Variables to take user input
variable "profile" {
  type = string
}

variable "key_name" {
  type = string
}

variable "instance_name" {
  type = string
}

variable "ebs_name" {
  type = string
}

variable "security_group_name" {
  type = string
}

variable "bucket_name" {
  type = string
}

# Specify provider and create infrastructure in Region US-WEST-2
provider "aws" {
  region  = "us-west-2"
  profile = var.profile
}

# Create private key for SSH into EC2. Save it as file named "mykey.pem" and set permission to rwx
resource "tls_private_key" "myprivatekey" {
  algorithm = "RSA"
  provisioner "local-exec" {
    command = "echo '${tls_private_key.myprivatekey.private_key_pem}' > mykey.pem && chmod 700 mykey.pem"
  }
}

# Create public key for SSH into EC2
resource "aws_key_pair" "mykeypair" {
  key_name   = var.key_name
  public_key = tls_private_key.myprivatekey.public_key_openssh
}

# Create security group to allow connections from port 80 and 22 from 0.0.0.0/0
resource "aws_security_group" "allow_tls" {
  name        = var.security_group_name
  description = "Allow TLS inbound traffic"

  ingress {
    description = "TLS from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from VPC"
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

  tags = {
    Name = var.security_group_name
  }
}

# Create aws instance.
resource "aws_instance" "webos" {
  ami             = "ami-0688ba7eeeeefe3cd"
  instance_type   = "t2.micro"
  key_name        = var.key_name
  security_groups = [aws_security_group.allow_tls.name]

  tags = {
    Name = var.instance_name
  }
}

# Create ebs volume as external hard disk for persistent storage for our code.
resource "aws_ebs_volume" "webebs" {
  availability_zone = aws_instance.webos.availability_zone
  size              = 1
  depends_on = [
    aws_instance.webos
  ]
  tags = {
    Name = var.ebs_name
  }
}

# Attach the ebs to ec2 instance
resource "aws_volume_attachment" "webebs_att" {
  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.webebs.id
  instance_id = aws_instance.webos.id

  depends_on = [
    aws_ebs_volume.webebs
  ]
  # Make connection to ec2 via SSH
  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.myprivatekey.private_key_pem
    host        = aws_instance.webos.public_ip
  }
  # Install httpd and git
  # Format the ebs volume and create a new partition
  # Mount the partition on web server directory
  # Download web code from github into webserver folder
  # Start webserver
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get install httpd git -y",
      "sudo mkfs.ext4 /dev/xvdh",
      "sudo mount /dev/xvdh /var/www/html",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/yfquek/free-test-web-template.git /var/www/html/",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd"
    ]
  }
}

# Create private S3 bucket
resource "aws_s3_bucket" "mybucket" {
  bucket = var.bucket_name
  #region = "us-west-2"

  tags = {
    Name        = var.bucket_name
    Environment = "Dev"
  }
}

resource "aws_s3_bucket_acl" "mybucket_acl" {
    bucket = var.bucket_name
    acl = "private"

    depends_on = [
    aws_s3_bucket.mybucket
  ]
}

# Upload files into S3 bucket
resource "aws_s3_object" "myobject" {
  bucket = var.bucket_name
  key    = "home.html"
  source = "/Users/yfquek/Documents/9x1-test-website/template/"
  acl    = "public-read"

  depends_on = [
    aws_s3_bucket.mybucket
  ]
}

# Create CF distribution
resource "aws_cloudfront_distribution" "mycloudfront" {
  depends_on = [
    aws_s3_bucket.mybucket
  ]
  origin {
    domain_name = aws_s3_bucket.mybucket.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.mybucket.id
  }
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "home.html"

  logging_config {
    include_cookies = false
    bucket          = aws_s3_bucket.mybucket.bucket_domain_name
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_s3_bucket.mybucket.id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Cache behavior with precedence 0
  ordered_cache_behavior {
    path_pattern     = "/content/immutable/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = aws_s3_bucket.mybucket.id

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  # Cache behavior with precedence 1
  ordered_cache_behavior {
    path_pattern     = "/content/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_s3_bucket.mybucket.id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Environment = "production"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "null_resource" "replace_src" {
  depends_on = [
    aws_cloudfront_distribution.mycloudfront
  ]
  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.myprivatekey.private_key_pem
    host        = aws_instance.webos.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo sed -i 's+cloudurl+https://${aws_cloudfront_distribution.mycloudfront.domain_name}/index.html+g' /var/www/html/index.html",
      "sudo systemctl restart httpd"
    ]
  }
}

output "webip" {
  value = aws_instance.webos.public_ip
}