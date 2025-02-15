#!/bin/bash

set -e  # Exit on any error
set -o pipefail
set -u  # Treat unset variables as an error

LOG_FILE="deploy.log"
exec > >(tee -i $LOG_FILE)
exec 2>&1

echo "[INFO] $(date) - Starting AWS Flask App Deployment..."

# Variables
KEY_NAME="flask-key"
SECURITY_GROUP_NAME="flask-sg"
IAM_ROLE_NAME="flask-app-role"
INSTANCE_PROFILE_NAME="flask-app-profile"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
REGION="us-east-1"
AMI_ID="ami-02354e95b39ca8dec"  # Amazon Linux 2 AMI
INSTANCE_TYPE="t2.micro"
FLASK_APP_ARCHIVE="flask-app.zip"

# Check for assume-role-policy.json
if [[ ! -f assume-role-policy.json ]]; then
  echo "[ERROR] Missing assume-role-policy.json. Ensure it exists."
  exit 1
fi

# Create Key Pair (if not exists)
if [[ ! -f "$KEY_NAME.pem" ]]; then
  echo "[INFO] Creating key pair..."
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "$KEY_NAME.pem"
  chmod 400 "$KEY_NAME.pem"
else
  echo "[INFO] Key pair already exists: $KEY_NAME.pem"
fi

# Create IAM Role (handle duplicate role)
if ! aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
  echo "[INFO] Creating IAM role..."
  aws iam create-role --role-name "$IAM_ROLE_NAME" --assume-role-policy-document file://assume-role-policy.json
else
  echo "[INFO] IAM role already exists."
fi

# Attach Policies to IAM Role
aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

# Create Instance Profile (avoid conflicts)
if ! aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" &>/dev/null; then
  echo "[INFO] Creating instance profile..."
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME"
else
  echo "[INFO] Instance profile already exists."
fi

# Create VPC, Subnet, Security Group
echo "[INFO] Setting up VPC and networking..."
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --query 'Vpc.VpcId' --output text)
SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $SUBNET_CIDR --query 'Subnet.SubnetId' --output text)
SG_ID=$(aws ec2 create-security-group --group-name "$SECURITY_GROUP_NAME" --description "Flask App SG" --vpc-id $VPC_ID --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0

# Launch EC2 Instance
echo "[INFO] Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI_ID --count 1 --instance-type $INSTANCE_TYPE --key-name "$KEY_NAME" --security-group-ids "$SG_ID" --subnet-id "$SUBNET_ID" --iam-instance-profile Name="$INSTANCE_PROFILE_NAME" --query 'Instances[0].InstanceId' --output text)

echo "[INFO] Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "[INFO] EC2 instance is now running at $PUBLIC_IP"

# Ensure Flask app archive exists
if [[ ! -f "$FLASK_APP_ARCHIVE" ]]; then
  echo "[ERROR] Flask app archive $FLASK_APP_ARCHIVE not found!"
  exit 1
fi

# Deploy Flask app to EC2
echo "[INFO] Deploying Flask app..."
scp -i "$KEY_NAME.pem" "$FLASK_APP_ARCHIVE" ec2-user@"$PUBLIC_IP":~
ssh -i "$KEY_NAME.pem" ec2-user@"$PUBLIC_IP" << EOF
  set -e
  echo "[INFO] Setting up Flask app on EC2..."
  
  # Install dependencies
  sudo yum update -y
  sudo yum install -y python3 python3-pip unzip

  # Unzip and set up Flask app
  unzip "$FLASK_APP_ARCHIVE" -d flask-app
  cd flask-app

  # Create virtual environment
  python3 -m venv venv
  source venv/bin/activate

  # Install Flask and Gunicorn
  pip install --upgrade pip
  pip install flask gunicorn

  # Run the app
  nohup gunicorn -b 0.0.0.0:80 app:app &

  echo "[INFO] Flask app deployed and running!"
EOF

echo "[INFO] Deployment complete. Access your Flask app at http://$PUBLIC_IP"
