#!/bin/bash

REGION="us-east-1"

echo "Starting full AWS cleanup in region: $REGION"

# Function to delete all instance profiles
delete_instance_profiles() {
    echo "Deleting all instance profiles..."
    INSTANCE_PROFILES=$(aws iam list-instance-profiles --query "InstanceProfiles[*].InstanceProfileName" --output text)

    for INSTANCE_PROFILE in $INSTANCE_PROFILES; do
        echo "Processing instance profile: $INSTANCE_PROFILE"

        # Get associated roles
        ROLES=$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --query "InstanceProfile.Roles[*].RoleName" --output text)
        for ROLE in $ROLES; do
            echo "Removing role $ROLE from instance profile: $INSTANCE_PROFILE"
            aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE" --role-name "$ROLE"
        done

        # Delete the instance profile
        aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE"
        echo "Instance profile deleted: $INSTANCE_PROFILE"
    done
}

# Call the function to remove instance profiles before deleting roles
delete_instance_profiles

# Function to delete IAM role, checking for dependencies
delete_iam_role() {
    ROLE_NAME=$1
    echo "Attempting to delete IAM role: $ROLE_NAME"

    # Check if the role is protected before modifying it
    PROTECTED_CHECK=$(aws iam get-role --role-name $ROLE_NAME 2>&1)
    if echo "$PROTECTED_CHECK" | grep -q "UnmodifiableEntity"; then
        echo "Skipping protected IAM role: $ROLE_NAME (Cannot delete due to protection)"
        return
    fi

    # Detach any policies attached to the IAM role
    POLICY_ARNS=$(aws iam list-attached-role-policies --role-name $ROLE_NAME --query "AttachedPolicies[*].PolicyArn" --output text)
    for POLICY_ARN in $POLICY_ARNS; do
        echo "Detaching policy $POLICY_ARN from IAM role $ROLE_NAME"
        DETACH_OUTPUT=$(aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN 2>&1)
        if echo "$DETACH_OUTPUT" | grep -q "UnmodifiableEntity"; then
            echo "Skipping policy detachment for protected IAM role: $ROLE_NAME"
            return
        fi
    done

    # Detach any instance profiles associated with the role
    INSTANCE_PROFILE_NAME=$(aws iam list-instance-profiles-for-role --role-name $ROLE_NAME --query "InstanceProfiles[*].InstanceProfileName" --output text)
    if [[ -n "$INSTANCE_PROFILE_NAME" ]]; then
        echo "Removing instance profile: $INSTANCE_PROFILE_NAME from IAM role $ROLE_NAME"
        aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$ROLE_NAME"
    fi

    # Now try to delete the IAM role
    DELETE_OUTPUT=$(aws iam delete-role --role-name $ROLE_NAME 2>&1)
    if echo "$DELETE_OUTPUT" | grep -q "UnmodifiableEntity"; then
        echo "Skipping protected IAM role: $ROLE_NAME (Cannot delete due to protection)"
    elif echo "$DELETE_OUTPUT" | grep -q "DependentResource"; then
        echo "Skipping IAM role $ROLE_NAME because it is in use by dependent resources."
    else
        echo "IAM role $ROLE_NAME deleted."
    fi
}

# List all IAM roles and attempt to delete each
echo "Deleting all IAM roles..."
ROLE_NAMES=$(aws iam list-roles --query "Roles[*].RoleName" --output text)
for ROLE_NAME in $ROLE_NAMES; do
    delete_iam_role $ROLE_NAME
done

# Function to delete a VPC and its associated resources
delete_vpc_resources() {
    VPC_ID=$1
    echo "Processing VPC: $VPC_ID"

    # Delete EC2 instances
    INSTANCE_IDS=$(aws ec2 describe-instances --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "Reservations[*].Instances[*].InstanceId" --output text)
    if [[ -n "$INSTANCE_IDS" ]]; then
        echo "Terminating EC2 instances: $INSTANCE_IDS"
        aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_IDS
        
        # Wait for EC2 instances to terminate
        echo "Waiting for EC2 instances to terminate..."
        aws ec2 wait instance-terminated --region $REGION --instance-ids $INSTANCE_IDS
        echo "EC2 instances terminated."
    fi

    # Detach and delete Security Groups (except default)
    SG_IDS=$(aws ec2 describe-security-groups --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
    for SG_ID in $SG_IDS; do
        echo "Detaching security group from resources: $SG_ID"

        # Detach from EC2 instances and ENIs
        ENI_IDS=$(aws ec2 describe-network-interfaces --region $REGION --filters "Name=group-id,Values=$SG_ID" --query "NetworkInterfaces[*].NetworkInterfaceId" --output text)
        if [[ -n "$ENI_IDS" ]]; then
            echo "Detaching security group from ENIs: $ENI_IDS"
            aws ec2 modify-network-interface-attribute --region $REGION --network-interface-id $ENI_IDS --no-groups
        fi

        # Detach from Load Balancers
        LB_IDS=$(aws elb describe-load-balancers --region $REGION --query "LoadBalancerDescriptions[?SecurityGroups=='$SG_ID'].LoadBalancerName" --output text)
        if [[ -n "$LB_IDS" ]]; then
            echo "Detaching security group from Load Balancers: $LB_IDS"
            aws elb modify-load-balancer-attributes --region $REGION --load-balancer-name $LB_IDS --security-groups ""
        fi

        # Delete the security group after detachment
        echo "Deleting Security Group: $SG_ID"
        aws ec2 delete-security-group --region $REGION --group-id $SG_ID
    done

    # Delete Subnets
    SUBNET_IDS=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text)
    for SUBNET_ID in $SUBNET_IDS; do
        echo "Deleting Subnet: $SUBNET_ID"
        aws ec2 delete-subnet --region $REGION --subnet-id $SUBNET_ID
    done

    # Release Elastic IPs
    EIP_ALLOC_IDS=$(aws ec2 describe-addresses --region $REGION --filters "Name=domain,Values=vpc" --query "Addresses[*].AllocationId" --output text)
    for EIP_ALLOC_ID in $EIP_ALLOC_IDS; do
        echo "Releasing Elastic IP: $EIP_ALLOC_ID"
        aws ec2 release-address --region $REGION --allocation-id $EIP_ALLOC_ID
    done

    # Detach and delete Internet Gateways
    IGW_IDS=$(aws ec2 describe-internet-gateways --region $REGION --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[*].InternetGatewayId" --output text)
    for IGW_ID in $IGW_IDS; do
        echo "Detaching and deleting Internet Gateway: $IGW_ID"
        aws ec2 detach-internet-gateway --region $REGION --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
        aws ec2 delete-internet-gateway --region $REGION --internet-gateway-id $IGW_ID
    done

    # Force delete Route Tables (including default ones)
    delete_route_tables() {
        echo "Checking and force deleting Route Tables..."
        RT_IDS=$(aws ec2 describe-route-tables --region $REGION --query "RouteTables[*].RouteTableId" --output text)

        for RT_ID in $RT_IDS; do
            # Attempt to force delete route table
            echo "Attempting to delete Route Table: $RT_ID"
            DELETION_OUTPUT=$(aws ec2 delete-route-table --region $REGION --route-table-id $RT_ID 2>&1)
        
            if echo "$DELETION_OUTPUT" | grep -q "DependencyViolation"; then
                # Skip printing the error message about dependencies
                echo "Route Table $RT_ID has dependencies and cannot be deleted right now (force delete later)"
            else
                echo "$DELETION_OUTPUT"  # Print the output if there are no errors
            fi
        done

        # Force delete route tables later (after disassociating subnets if necessary)
        for RT_ID in $RT_IDS; do
            echo "Force deleting Route Table: $RT_ID"
            SUBNET_ASSOCIATIONS=$(aws ec2 describe-route-tables --region $REGION --route-table-id $RT_ID --query "RouteTables[*].Associations[?Main!=\`true\`].AssociationId" --output text)
        
            if [[ -n "$SUBNET_ASSOCIATIONS" ]]; then
                for ASSOC_ID in $SUBNET_ASSOCIATIONS; do
                    echo "Disassociating subnet from route table: $ASSOC_ID"
                    aws ec2 disassociate-route-table --region $REGION --association-id $ASSOC_ID
                done
            fi
        
            # Retry the deletion to force the route table removal
            aws ec2 delete-route-table --region $REGION --route-table-id $RT_ID
            echo "Route Table $RT_ID deleted."
        done
    }

    # Call the route table cleanup function
    delete_route_tables

    # Delete NAT Gateways
    NAT_GW_IDS=$(aws ec2 describe-nat-gateways --region $REGION --filter "Name=vpc-id,Values=$VPC_ID" --query "NatGateways[*].NatGatewayId" --output text)
    for NAT_GW_ID in $NAT_GW_IDS; do
        echo "Deleting NAT Gateway: $NAT_GW_ID"
        aws ec2 delete-nat-gateway --region $REGION --nat-gateway-id $NAT_GW_ID
        sleep 10  # Allow deletion to process
    done

    # Delete Network Interfaces (ENIs)
    ENI_IDS=$(aws ec2 describe-network-interfaces --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "NetworkInterfaces[*].NetworkInterfaceId" --output text)
    for ENI_ID in $ENI_IDS; do
        echo "Deleting Network Interface: $ENI_ID"
        aws ec2 delete-network-interface --region $REGION --network-interface-id $ENI_ID
    done

    # Delete VPC Peering Connections (if any)
    PEER_IDS=$(aws ec2 describe-vpc-peering-connections --region $REGION --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" --query "VpcPeeringConnections[*].VpcPeeringConnectionId" --output text)
    for PEER_ID in $PEER_IDS; do
        echo "Deleting VPC Peering Connection: $PEER_ID"
        aws ec2 delete-vpc-peering-connection --region $REGION --vpc-peering-connection-id $PEER_ID
    done

    # Try deleting the VPC
    echo "Attempting to delete VPC: $VPC_ID"
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
    
    # Wait for EC2 instances to terminate
    echo "Waiting for EC2 instances to terminate..."
    aws ec2 wait instance-terminated --region $REGION --instance-ids $INSTANCE_IDS
    echo "EC2 instances terminated."
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
echo "$untracked_files"

echo "Full cleanup completed."
