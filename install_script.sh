Refine script? #!/bin/bash
set -e

# Set variables
AWS_REGION="us-east-1"
KEY_PAIR_NAME="my-key"
SECURITY_GROUP_NAME="flask-security-group"
VPC_NAME="flask-vpc"
SUBNET_NAME="flask-subnet"
INSTANCE_TYPE="t2.micro"
IAM_ROLE="flask-app-role"  # Replace with your IAM role if needed
REPOSITORY_URL="https://github.com/mikebelus/flask-app.git"
YOUR_IP="YOUR_IP/32"  # Replace with your actual IP for SSH access

# Logging function
log() {
  echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Get the latest Amazon Linux 2 AMI ID
log "Getting the latest Amazon Linux 2 AMI ID..."
AMI_ID=$(aws ec2 describe-images \
  --region $AWS_REGION \
  --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
  --owners amazon \
  --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
  --output text)
log "Using AMI ID: $AMI_ID"

# Create a new key pair
log "Creating key pair..."
aws ec2 create-key-pair --region $AWS_REGION --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --output text > $KEY_PAIR_NAME.pem
chmod 400 $KEY_PAIR_NAME.pem

# Create a VPC
log "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --region $AWS_REGION --cidr-block "10.0.0.0/16" --query 'Vpc.VpcId' --output text)
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
log "VPC ID: $VPC_ID"

# Create a subnet
log "Creating subnet..."
SUBNET_ID=$(aws ec2 create-subnet --region $AWS_REGION --vpc-id $VPC_ID --cidr-block "10.0.1.0/24" --query 'Subnet.SubnetId' --output text)
log "Subnet ID: $SUBNET_ID"

# Create a security group
log "Creating security group..."
SECURITY_GROUP_ID=$(aws ec2 create-security-group --region $AWS_REGION --group-name $SECURITY_GROUP_NAME --description "Security group for Flask app" --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 22 --cidr $YOUR_IP  # Restrict SSH
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 80 --cidr 0.0.0.0/0  # Allow HTTP
aws ec2 authorize-security-group-ingress --region $AWS_REGION --group-id $SECURITY_GROUP_ID --protocol tcp --port 443 --cidr 0.0.0.0/0  # Allow HTTPS
log "Security group ID: $SECURITY_GROUP_ID"

# Launch EC2 instance
log "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances --region $AWS_REGION --image-id $AMI_ID --count 1 --instance-type $INSTANCE_TYPE --key-name $KEY_PAIR_NAME --security-group-ids $SECURITY_GROUP_ID --subnet-id $SUBNET_ID --iam-instance-profile Name=$IAM_ROLE --associate-public-ip-address --query 'Instances[0].InstanceId' --output text)
log "Instance ID: $INSTANCE_ID"

# Wait for the instance to be in 'running' state
log "Waiting for instance to be running..."
aws ec2 wait instance-running --region $AWS_REGION --instance-ids $INSTANCE_ID

# Get the public IP of the EC2 instance
PUBLIC_IP=$(aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
log "EC2 instance is running. Public IP: $PUBLIC_IP"

# SSH into the EC2 instance and set up the Flask app
log "Setting up Flask app on EC2..."
ssh -o StrictHostKeyChecking=no -i $KEY_PAIR_NAME.pem ec2-user@$PUBLIC_IP << EOF
    set -e

    # Update the system
    sudo yum update -y

    # Install necessary dependencies
    sudo yum install -y python3 python3-pip gcc git firewalld

    # Enable firewall and allow HTTP and HTTPS traffic
    sudo systemctl enable firewalld --now
    sudo firewall-cmd --permanent --add-service=http
    sudo firewall-cmd --permanent --add-service=https
    sudo firewall-cmd --reload

    # Create a dedicated user for the Flask app
    sudo useradd -m -s /bin/bash flaskuser
    sudo su - flaskuser << FLASK_SETUP

        # Clone the Flask app repository
        git clone $REPOSITORY_URL flask-app
        cd flask-app

        # Set up a virtual environment
        python3 -m venv venv
        source venv/bin/activate

        # Install Flask & Gunicorn
        pip install --upgrade pip
        pip install flask gunicorn

        # Deactivate virtual environment
        deactivate
FLASK_SETUP

    # Create a systemd service for Gunicorn
    sudo tee /etc/systemd/system/flask.service > /dev/null << SERVICE
[Unit]
Description=Gunicorn instance to serve Flask app
After=network.target

[Service]
User=flaskuser
Group=flaskuser
WorkingDirectory=/home/flaskuser/flask-app
ExecStart=/home/flaskuser/flask-app/venv/bin/gunicorn -w 4 -b 0.0.0.0:80 wsgi:app
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE

    # Set correct permissions
    sudo chown -R flaskuser:flaskuser /home/flaskuser/flask-app

    # Reload systemd, enable and start the Flask service
    sudo systemctl daemon-reload
    sudo systemctl enable flask
    sudo systemctl start flask

    log "Flask app started successfully"
EOF

# Done
log "Flask app is running at http://$PUBLIC_IP"

# Optional cleanup: Delete security group
log "Cleaning up security group..."
aws ec2 delete-security-group --region $AWS_REGION --group-id $SECURITY_GROUP_ID || log "Failed to delete security group. It might be in use."

# Optional cleanup: Terminate EC2 instance
log "Terminating EC2 instance..."
aws ec2 terminate-instances --region $AWS_REGION --instance-ids $INSTANCE_ID || log "Failed to terminate instance."
aws ec2 wait instance-terminated --region $AWS_REGION --instance-ids $INSTANCE_ID
log "EC2 instance terminated."
