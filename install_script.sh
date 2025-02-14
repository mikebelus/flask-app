#!/bin/bash

# Set variables
AWS_REGION="us-east-1"
KEY_PAIR_NAME="my-key"
SECURITY_GROUP_NAME="flask-security-group"
VPC_NAME="flask-vpc"
SUBNET_NAME="flask-subnet"
INSTANCE_TYPE="t2.micro"
REPOSITORY_URL="https://github.com/yourusername/flask-app.git"  # Replace with your GitHub repo URL

# Get the latest Amazon Linux 2 AMI ID for the region
echo "Getting the latest Amazon Linux 2 AMI ID..."
AMI_ID=$(aws ec2 describe-images \
  --region $AWS_REGION \
  --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
  --owners amazon \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
  --output text)
echo "Using AMI ID: $AMI_ID"

# Create a new key pair
echo "Creating key pair..."
aws ec2 create-key-pair --region $AWS_REGION --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --output text > $KEY_PAIR_NAME.pem
chmod 400 $KEY_PAIR_NAME.pem

# Create a VPC
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --region $AWS_REGION --cidr-block "10.0.0.0/16" --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
echo "VPC ID: $VPC_ID"

# Create a subnet in the VPC
echo "Creating subnet..."
SUBNET_ID=$(aws ec2 create-subnet --region $AWS_REGION --vpc-id $VPC_ID --cidr-block "10.0.1.0/24" --query 'Subnet.SubnetId' --output text)
echo "Subnet ID: $SUBNET_ID"

# Create a security group
echo "Creating security group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group --region $AWS_REGION --group-name $SECURITY_GROUP_NAME --description "Security group for Flask app" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
echo "Security group ID: $SECURITY_GROUP_ID"

# Launch EC2 instance
echo "Launching EC2 instance..."

INSTANCE_ID=$(aws ec2 run-instances --region $AWS_REGION --image-id $AMI_ID --count 1 --instance-type $INSTANCE_TYPE --key-name $KEY_PAIR_NAME --security-group-ids $SECURITY_GROUP_ID --subnet-id $SUBNET_ID --associate-public-ip-address --query 'Instances[0].InstanceId' --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for the instance to be in 'running' state
echo "Waiting for instance to be running..."
aws ec2 wait instance-running --region $AWS_REGION --instance-ids $INSTANCE_ID

# Get the public IP of the EC2 instance
PUBLIC_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "EC2 instance is running. Public IP: $PUBLIC_IP"

# SSH into the EC2 instance and set up the Flask app
echo "Setting up Flask app on EC2..."
ssh -o StrictHostKeyChecking=no -i $KEY_PAIR_NAME.pem ec2-user@$PUBLIC_IP << 'EOF'
    # Update the system
    sudo yum update -y

    # Install Python and pip
    sudo yum install python3 -y
    sudo yum install git -y

    # Install necessary Python packages
    python3 -m pip install --upgrade pip
    pip3 install flask gunicorn

    # Clone the Flask app repository
    git clone https://github.com/yourusername/flask-app.git

    # Navigate to the app directory
    cd flask-app

    # Run Gunicorn to start the Flask app
    gunicorn -w 4 -b 0.0.0.0:80 wsgi:app
EOF

# Done
echo "Flask app is running at http://$PUBLIC_IP"
