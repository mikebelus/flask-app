#!/bin/bash
set -euo pipefail  # Enable strict error handling

# Print log function for standardized logging
print_log() {
  echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

# Set variables
AWS_REGION="us-east-1"
KEY_PAIR_NAME="my-key"
SECURITY_GROUP_NAME="flask-security-group"
INSTANCE_TYPE="t2.micro"
IAM_ROLE=""  # Set to an IAM role if needed
REPOSITORY_URL="https://github.com/mikebelus/flask-app.git"

# Detect public IP automatically
detect_public_ip() {
  print_log "Detecting public IP..."
  local ip
  ip=$(curl -s https://ifconfig.me) || { print_log "[ERROR] Failed to detect public IP."; exit 1; }
  echo "$ip/32"
}

# Automatically set YOUR_IP using detect_public_ip
YOUR_IP=$(detect_public_ip)

print_log "Detected public IP: $YOUR_IP"

# Create VPC
create_vpc() {
  print_log "Creating a new VPC..."
  local vpc_id
  vpc_id=$(aws ec2 create-vpc --region "$AWS_REGION" --cidr-block "10.0.0.0/16" \
    --query 'Vpc.VpcId' --output text | tr -d '\r' || { print_log "[ERROR] Failed to create VPC."; exit 1; })

  print_log "VPC created successfully with ID: $vpc_id"
  echo "$vpc_id"
}

# Fetch latest Amazon Linux 2 AMI ID
get_ami_id() {
  print_log "Fetching the latest Amazon Linux 2 AMI ID..."
  local ami_id
  ami_id=$(aws ec2 describe-images --region "$AWS_REGION" \
    --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" \
    --owners amazon \
    --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" --output text)

  if [[ -z "$ami_id" ]]; then
    print_log "[ERROR] Failed to fetch the Amazon Linux 2 AMI ID."
    exit 1
  fi

  echo "$ami_id"
}

# Create key pair if it does not exist
create_key_pair() {
  print_log "Checking if key pair '$KEY_PAIR_NAME' exists..."
  if aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_PAIR_NAME" &>/dev/null; then
    print_log "Key pair '$KEY_PAIR_NAME' already exists, skipping creation."
  else
    print_log "Creating key pair '$KEY_PAIR_NAME'..."
    aws ec2 create-key-pair --region "$AWS_REGION" --key-name "$KEY_PAIR_NAME" \
      --query 'KeyMaterial' --output text > "$KEY_PAIR_NAME.pem" || { print_log "[ERROR] Failed to create key pair."; exit 1; }
    chmod 400 "$KEY_PAIR_NAME.pem"
  fi
}

# Create or retrieve security group
create_security_group() {
  local vpc_id=$1
  print_log "Checking for existing security group..."
  local group_id
  group_id=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=$SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

  if [[ -z "$group_id" ]]; then
    print_log "Creating security group '$SECURITY_GROUP_NAME' in VPC $vpc_id..."
    group_id=$(aws ec2 create-security-group --region "$AWS_REGION" \
      --group-name "$SECURITY_GROUP_NAME" --description "Flask security group" \
      --vpc-id "$vpc_id" --query 'GroupId' --output text) || { print_log "[ERROR] Failed to create security group."; exit 1; }

    print_log "Configuring security group rules..."
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$group_id" --protocol tcp --port 22 --cidr "$YOUR_IP" || { print_log "[ERROR] Failed to configure SSH access."; exit 1; }
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$group_id" --protocol tcp --port 80 --cidr "0.0.0.0/0" || { print_log "[ERROR] Failed to configure HTTP access."; exit 1; }
  else
    print_log "Security group '$SECURITY_GROUP_NAME' already exists with ID: $group_id."
  fi

  echo "$group_id"
}

# Launch EC2 instance
launch_instance() {
  local ami_id=$1
  local security_group_id=$2

  print_log "Launching EC2 instance with AMI: $ami_id and security group: $security_group_id..."
  local instance_id
  instance_id=$(aws ec2 run-instances --region "$AWS_REGION" --image-id "$ami_id" --count 1 --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_PAIR_NAME" --security-group-ids "$security_group_id" --associate-public-ip-address \
    --query 'Instances[0].InstanceId' --output text) || { print_log "[ERROR] Failed to launch EC2 instance."; exit 1; }

  echo "$instance_id"
}

# Wait for EC2 instance to start
wait_for_instance() {
  local instance_id=$1
  print_log "Waiting for EC2 instance $instance_id to be running..."
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$instance_id" || { print_log "[ERROR] Failed to wait for EC2 instance to run."; exit 1; }
}

# Get EC2 instance public IP
get_public_ip() {
  local instance_id=$1
  local public_ip
  public_ip=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text) || { print_log "[ERROR] Failed to fetch public IP."; exit 1; }

  if [[ -z "$public_ip" ]]; then
    print_log "[ERROR] Failed to fetch public IP for instance $instance_id."
    exit 1
  fi

  echo "$public_ip"
}

# Deploy Flask app on EC2 instance
deploy_flask() {
  print_log "Deploying Flask app on EC2 instance..."
  local public_ip=$1
  ssh -T -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -i "$KEY_PAIR_NAME.pem" ec2-user@"$public_ip" << EOF
    set -e
    sudo yum update -y
    sudo yum install -y python3 python3-pip gcc git firewalld
    sudo systemctl enable --now firewalld
    sudo firewall-cmd --permanent --add-service=http
    sudo firewall-cmd --permanent --add-service=https
    sudo firewall-cmd --reload

    sudo useradd -m -s /bin/bash flaskuser
    sudo -u flaskuser bash -c "
      cd ~;
      git clone $REPOSITORY_URL flask-app;
      cd flask-app;
      python3 -m venv venv;
      source venv/bin/activate;
      pip install --upgrade pip;
      pip install flask gunicorn;
      deactivate;
    "

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

    sudo chown -R flaskuser:flaskuser /home/flaskuser/flask-app
    sudo systemctl daemon-reload
    sudo systemctl enable flask
    sudo systemctl restart flask
EOF
}

# Cleanup AWS resources
cleanup() {
  local instance_id=$1
  local security_group_id=$2
  local vpc_id=$3

  print_log "Terminating EC2 instance $instance_id..."
  aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$instance_id"
  aws ec2 wait instance-terminated --region "$AWS_REGION" --instance-ids "$instance_id" || { print_log "[ERROR] Failed to terminate EC2 instance."; exit 1; }

  print_log "Deleting key pair..."
  aws ec2 delete-key-pair --region "$AWS_REGION" --key-name "$KEY_PAIR_NAME"
  rm -f "$KEY_PAIR_NAME.pem"

  print_log "Checking if security group is still in use..."
  if ! aws ec2 describe-instances --region "$AWS_REGION" --filters "Name=instance.group-id,Values=$security_group_id" \
    --query "Reservations[*].Instances[*].InstanceId" --output text | grep .; then
    print_log "Deleting security group..."
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$security_group_id"
  else
    print_log "Security group is still in use, not deleting."
  fi

  print_log "Deleting VPC $vpc_id..."
  aws ec2 delete-vpc --region "$AWS_REGION" --vpc-id "$vpc_id" || { print_log "[ERROR] Failed to delete VPC."; exit 1; }
}

# Main execution flow
vpc_id=$(create_vpc)
ami_id=$(get_ami_id)
create_key_pair
security_group_id=$(create_security_group "$vpc_id")
instance_id=$(launch_instance "$ami_id" "$security_group_id")
wait_for_instance "$instance_id"
public_ip=$(get_public_ip "$instance_id")
deploy_flask "$public_ip"

print_log "Flask app deployed successfully at http://$public_ip"

# Uncomment the following line to clean up resources after deployment
# cleanup "$instance_id" "$security_group_id" "$vpc_id"
