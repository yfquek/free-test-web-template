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

provider "aws" {
    region = "us-west-1"
    profile = var.profile
}

resource "tls_private_key" "myprivatekey" {
  algorithm   = "RSA"
  provisioner "local-exec" {
        command = "echo '${tls_private_key.myprivatekey.private_key_pem}' > mykey.pem && chmod 400 mykey.pem"
    }
}

resource "aws_key_pair" "mykeypair" {
  key_name   = var.key_name
  public_key = tls_private_key.myprivatekey.public_key_openssh
}

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

resource "aws_instance" "webos" {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = var.key_name
  security_groups = [ aws_security_group.allow_tls.name ]

  tags = {
    Name = var.instance_name
  }
}

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
resource "aws_volume_attachment" "webebs_att" {
    device_name = "/dev/sdh"
    volume_id   = aws_ebs_volume.webebs.id
    instance_id = aws_instance.webos.id
    
    depends_on = [
        aws_ebs_volume.webebs
    ]

    connection {
          type = "ssh"
          user = "ec2-user"
          private_key = tls_private_key.myprivatekey.private_key_pem
          host = aws_instance.webos.public_ip
      }

    provisioner "remote-exec" {
      inline = [
          "sudo yum install httpd git -y",
          "sudo mkfs.ext4 /dev/xvdh",
          "sudo mount /dev/xvdh /var/www/html",
          "sudo rm -rf /var/www/html/*",
          "sudo git clone https://github.com/dheeth/httpd.git /var/www/html/",
          "sudo systemctl restart httpd",
          "sudo systemctl enable httpd"
      ]
  }
}

resource "aws_s3_bucket" "mybucket" {
  bucket = var.bucket_name
  region = "ap-south-1"
  acl    = "private"

  tags = {
    Name        = var.bucket_name
    Environment = "Dev"
  }
}

resource "aws_s3_bucket_object" "myobject" {
  bucket = var.bucket_name
  key    = "pawan.jpg"
  source = "/home/dheeth/Desktop/LW/gitkube/PicsArt_10-05-09.37.09.jpg"
  acl = "public-read"

  depends_on = [
    aws_s3_bucket.mybucket
  ]
}

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
  default_root_object = "pawan.jpg"

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
          type = "ssh"
          user = "ec2-user"
          private_key = tls_private_key.myprivatekey.private_key_pem
          host = aws_instance.webos.public_ip
      }

    provisioner "remote-exec" {
      inline = [
          "sudo sed -i 's+cloudurl+https://${aws_cloudfront_distribution.mycloudfront.domain_name}/pawan.jpg+g' /var/www/html/index.html",
          "sudo systemctl restart httpd"
      ]
}
}

output "webip" {
    value = aws_instance.webos.public_ip
}