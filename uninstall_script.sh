#!/bin/bash

REGION="us-east-1"

echo "Starting full AWS cleanup in region: $REGION"

# Function to delete a VPC and its associated resources
delete_vpc_resources() {
    VPC_ID=$1
    echo "Processing VPC: $VPC_ID"

    # Delete EC2 instances
    INSTANCE_IDS=$(aws ec2 describe-instances --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "Reservations[*].Instances[*].InstanceId" --output text)
    if [[ -n "$INSTANCE_IDS" ]]; then
        echo "Terminating EC2 instances: $INSTANCE_IDS"
        aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_IDS
        sleep 10  # Allow instances to terminate
    fi

    # Detach and delete Security Groups (except default)
    SG_IDS=$(aws ec2 describe-security-groups --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
    for SG_ID in $SG_IDS; do
        # Check if security group is in use by any resource
        ENI_IDS=$(aws ec2 describe-network-interfaces --region $REGION --filters "Name=group-id,Values=$SG_ID" --query "NetworkInterfaces[*].NetworkInterfaceId" --output text)
        if [[ -n "$ENI_IDS" ]]; then
            echo "Detaching security group from ENIs: $ENI_IDS"
            aws ec2 modify-network-interface-attribute --region $REGION --network-interface-id $ENI_IDS --no-groups
        fi

        # Detach security group from Load Balancers
        LB_IDS=$(aws elb describe-load-balancers --region $REGION --query "LoadBalancerDescriptions[?SecurityGroups=='$SG_ID'].LoadBalancerName" --output text)
        if [[ -n "$LB_IDS" ]]; then
            echo "Detaching security group from Load Balancers: $LB_IDS"
            aws elb modify-load-balancer-attributes --region $REGION --load-balancer-name $LB_IDS --security-groups ""
        fi

        # Now delete security group
        echo "Deleting Security Group: $SG_ID"
        aws ec2 delete-security-group --region $REGION --group-id $SG_ID
    done

    # Delete Subnets
    SUBNET_IDS=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)
    for SUBNET_ID in $SUBNET_IDS; do
        echo "Deleting Subnet: $SUBNET_ID"
        aws ec2 delete-subnet --region $REGION --subnet-id $SUBNET_ID
    done

    # Delete NAT Gateways
    NAT_GW_IDS=$(aws ec2 describe-nat-gateways --region $REGION --filter "Name=vpc-id,Values=$VPC_ID" --query "NatGateways[*].NatGatewayId" --output text)
    for NAT_GW_ID in $NAT_GW_IDS; do
        echo "Deleting NAT Gateway: $NAT_GW_ID"
        aws ec2 delete-nat-gateway --region $REGION --nat-gateway-id $NAT_GW_ID
        sleep 10  # Allow deletion to process
    done

    # Delete Internet Gateways
    IGW_IDS=$(aws ec2 describe-internet-gateways --region $REGION --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[*].InternetGatewayId" --output text)
    for IGW_ID in $IGW_IDS; do
        echo "Detaching and deleting Internet Gateway: $IGW_ID"
        aws ec2 detach-internet-gateway --region $REGION --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
        aws ec2 delete-internet-gateway --region $REGION --internet-gateway-id $IGW_ID
    done

    # Delete Route Tables (EXCEPT main)
    RT_IDS=$(aws ec2 describe-route-tables --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[?Associations[0].Main==\`false\`].RouteTableId" --output text)
    for RT_ID in $RT_IDS; do
        echo "Deleting Route Table: $RT_ID"
        aws ec2 delete-route-table --region $REGION --route-table-id $RT_ID
    done

    # Delete the VPC
    echo "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc --region $REGION --vpc-id $VPC_ID
}

# Get all VPCs
VPC_IDS=$(aws ec2 describe-vpcs --region $REGION --query "Vpcs[*].VpcId" --output text)
for VPC_ID in $VPC_IDS; do
    delete_vpc_resources $VPC_ID
done

echo "VPC cleanup completed."

# Delete S3 Buckets
echo "Checking for S3 buckets..."
BUCKETS=$(aws s3api list-buckets --query "Buckets[*].Name" --output text)
for BUCKET in $BUCKETS; do
    echo "Deleting S3 bucket: $BUCKET"
    aws s3 rb "s3://$BUCKET" --force
done

# Delete EC2 instances
echo "Checking for EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances --region $REGION --query "Reservations[*].Instances[*].InstanceId" --output text)
if [[ -n "$INSTANCE_IDS" ]]; then
    echo "Terminating EC2 instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_IDS
    sleep 10
fi

# Delete Key Pairs
echo "Checking for Key Pairs..."
KEY_PAIRS=$(aws ec2 describe-key-pairs --region $REGION --query "KeyPairs[*].KeyName" --output text)
for KEY in $KEY_PAIRS; do
    echo "Deleting Key Pair: $KEY"
    aws ec2 delete-key-pair --region $REGION --key-name "$KEY"
done

# Delete AMIs
echo "Checking for AMIs..."
AMI_IDS=$(aws ec2 describe-images --region $REGION --owners self --query "Images[*].ImageId" --output text)
for AMI in $AMI_IDS; do
    echo "Deregistering AMI: $AMI"
    aws ec2 deregister-image --region $REGION --image-id $AMI
done

# Delete Snapshots
echo "Checking for Snapshots..."
SNAPSHOT_IDS=$(aws ec2 describe-snapshots --region $REGION --owner-ids self --query "Snapshots[*].SnapshotId" --output text)
for SNAPSHOT in $SNAPSHOT_IDS; do
    echo "Deleting Snapshot: $SNAPSHOT"
    aws ec2 delete-snapshot --region $REGION --snapshot-id $SNAPSHOT
done

# Delete EBS Volumes
echo "Checking for EBS Volumes..."
VOLUME_IDS=$(aws ec2 describe-volumes --region $REGION --query "Volumes[*].VolumeId" --output text)
for VOLUME in $VOLUME_IDS; do
    echo "Deleting Volume: $VOLUME"
    aws ec2 delete-volume --region $REGION --volume-id $VOLUME
done

# Final AWS cost check
echo "Fetching AWS cost and usage..."
Start=$(date -v1d +%Y-%m-%d)  # macOS-compatible date command
End=$(date +%Y-%m-%d)

aws ce get-cost-and-usage --time-period Start=$Start,End=$End --granularity MONTHLY --metrics "UnblendedCost"

# Fetch AWS cost forecast
echo "Fetching AWS cost forecast..."
ForecastStart=$(date +%Y-%m-%d)
ForecastEnd=$(date -v+1m -v1d +%Y-%m-%d)

aws ce get-cost-forecast --time-period Start=$ForecastStart,End=$ForecastEnd --metric "UNBLENDED_COST" --granularity MONTHLY

# Securely delete any remaining .pem files
echo "Deleting any remaining .pem files..."
rm -f *.pem

# Sync up the local repository
echo "Syncing local repository with remote..."
git pull origin main
git add .
git commit -m "Cleanup script: removed AWS resources and synced repo"
git push origin main

# Check for files not tracked in Git
echo "==== Local files not in either repository ===="
untracked_files=$(git ls-files --others --exclude-standard)
if [[ -z "$untracked_files" ]]; then
    echo "No untracked local files found."
else
    echo "$untracked_files"
fi
echo "================================"

echo "AWS cleanup complete!"
