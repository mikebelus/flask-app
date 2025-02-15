#!/bin/bash

# Set variables
AWS_REGION="us-east-1"
KEY_NAME="flask-key"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
INSTANCE_TYPE="t2.micro"
AMI_ID="ami-0c104f6f4a5d9d1d5"  # Amazon Linux 2 AMI ID
SECURITY_GROUP_NAME="flask-sg"
ROLE_NAME="flask-app-role"
PROFILE_NAME="flask-app-profile"

# Logging function
log() {
  echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# 1. Create key pair for SSH access
log "Creating key pair..."
aws ec2 create-key-pair --region $AWS_REGION --key-name $KEY_NAME --query 'KeyMaterial' --output text > ${KEY_NAME}.pem
chmod 400 ${KEY_NAME}.pem
log "Key pair created: ${KEY_NAME}.pem"

# 2. Create IAM role for EC2 instance
log "Creating IAM role: $ROLE_NAME..."
ROLE_ARN=$(aws iam create-role --region $AWS_REGION --role-name $ROLE_NAME --assume-role-policy-document file://assume-role-policy.json --query 'Role.Arn' --output text)

# 3. Attach policies to IAM role
log "Attaching policies to IAM role..."
aws iam attach-role-policy --region $AWS_REGION --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-role-policy --region $AWS_REGION --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
log "Policies attached to IAM role."

# 4. Create instance profile
log "Creating instance profile: $PROFILE_NAME..."
aws iam create-instance-profile --region $AWS_REGION --instance-profile-name $PROFILE_NAME
aws iam add-role-to-instance-profile --region $AWS_REGION --instance-profile-name $PROFILE_NAME --role-name $ROLE_NAME
log "Instance profile created and role added."

# 5. Create VPC
log "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --region $AWS_REGION --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
log "VPC created: $VPC_ID"

# 6. Create subnet
log "Creating subnet..."
SUBNET_ID=$(aws ec2 create-subnet --region $AWS_REGION --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR --query 'Subnet.SubnetId' --output text)
log "Subnet created: $SUBNET_ID"

# 7. Create and attach Internet Gateway
log "Creating internet gateway..."
IGW_ID=$(aws ec2 create-internet-gateway --region $AWS_REGION --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --region $AWS_REGION --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
log "Internet Gateway created and attached: $IGW_ID"

# 8. Create route table and add route to Internet Gateway
log "Creating route table..."
ROUTE_TABLE_ID=$(aws ec2 create-route-table --region $AWS_REGION --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region $AWS_REGION --route-table-id $ROUTE_TABLE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
log "Route table created and route added to Internet Gateway."

# 9. Associate route table with subnet
log "Associating route table with subnet..."
aws ec2 associate-route-table --region $AWS_REGION --subnet-id $SUBNET_ID --route-table-id $ROUTE_TABLE_ID
log "Route table associated with subnet."

# 10. Create security group
log "Creating security group: $SECURITY_GROUP_NAME..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group --region $AWS_REGION --group-name $SECURITY_GROUP_NAME --description "Security group for Flask app" --vpc-id $VPC_ID --query 'GroupId' --output text)

# Allow SSH, HTTP, and HTTPS access
log "Configuring security group rules..."
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 443 --cidr 0.0.0.0/0
log "Security group configured: $SECURITY_GROUP_ID"

# 11. Launch EC2 instance with IAM role and security group
log "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances --region $AWS_REGION --image-id $AMI_ID --instance-type $INSTANCE_TYPE --key-name $KEY_NAME --security-group-ids $SECURITY_GROUP_ID --subnet-id $SUBNET_ID --iam-instance-profile Name=$PROFILE_NAME --associate-public-ip-address --query 'Instances[0].InstanceId' --output text)
log "EC2 instance launched: $INSTANCE_ID"

# 12. Wait for EC2 instance to be running
log "Waiting for instance to be running..."
aws ec2 wait instance-running --region $AWS_REGION --instance-ids $INSTANCE_ID
log "EC2 instance is now running."

# 13. Get the public IP address of the EC2 instance
PUBLIC_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "Public IP of EC2 instance: $PUBLIC_IP"

# 14. Set up Flask app on EC2 instance
log "Setting up Flask app on EC2..."
scp -i ${KEY_NAME}.pem flask-app.zip ec2-user@$PUBLIC_IP:/home/ec2-user/
ssh -i ${KEY_NAME}.pem ec2-user@$PUBLIC_IP <<EOF
  unzip flask-app.zip
  cd flask-app
  sudo yum install -y python3 python3-pip
  sudo pip3 install flask gunicorn
  nohup gunicorn app:app --bind 0.0.0.0:5000 &
EOF

log "Flask app setup completed on EC2 instance."

log "EC2 instance setup completed. You can access the Flask app at http://$PUBLIC_IP:5000."
