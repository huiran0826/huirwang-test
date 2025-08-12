export NODE_IP_NAME="ip-10-0-49-31.us-east-2.compute.internal"
export REGION="us-east-2" 
export TARGET_INSTANCE_NAME="bgp-0806-int-svc" 

# Get instance ID
NODE_INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
  --filters "Name=private-dns-name,Values=$NODE_IP_NAME" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

echo "Instance ID $NODE_INSTANCE_ID"

# Get subnet ID
SUBNET_ID=$(aws ec2 describe-instances --region $REGION \
  --instance-ids "$NODE_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SubnetId" --output text)

echo " Subnet ID: $SUBNET_ID"


# Get security group with "-node" suffix
SECURITY_GROUP_ID=$(aws ec2 describe-instances --region $REGION \
  --instance-ids "$NODE_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[?ends_with(GroupName, '-node')].GroupId" \
  --output text)

echo $SECURITY_GROUP_ID


echo "Security Group ID (ends with -node): $SECURITY_GROUP_ID"

echo " Step 2: Create a new ENI in the subnet"
ENI_ID=$(aws ec2 create-network-interface \
  --region $REGION \
  --subnet-id "$SUBNET_ID" \
  --groups "$SECURITY_GROUP_ID" \
  --description "ENI for $TARGET_INSTANCE_NAME" \
  --query 'NetworkInterface.NetworkInterfaceId' \
  --output text)

echo "ENI ID: $ENI_ID"

echo "🔗 Step 3: Attach ENI to instance: $TARGET_INSTANCE_NAME"
TARGET_INSTANCE_ID=$(aws ec2 describe-instances --region $REGION \
  --filters "Name=tag:Name,Values=$TARGET_INSTANCE_NAME" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

echo  "Target int-svc instance ID $TARGET_INSTANCE_ID"

ATTACHMENT_ID=$(aws ec2 attach-network-interface \
  --region $REGION \
  --network-interface-id "$ENI_ID" \
  --instance-id "$TARGET_INSTANCE_ID" \
  --device-index 1 \
  --query 'AttachmentId' --output text)

echo "Attachment ID: $ATTACHMENT_ID"
echo "🔗 Attached ENI $ENI_ID to instance $TARGET_INSTANCE_ID as device-index 1"

echo "Step 4: Disable source/destination check on all ENIs in subnet $SUBNET_ID"
ENIS_IN_SUBNET=$(aws ec2 describe-network-interfaces \
  --region $REGION \
  --filters "Name=subnet-id,Values=$SUBNET_ID" \
  --query "NetworkInterfaces[*].NetworkInterfaceId" --output text)

echo "ENIS_IN_SUBNET: $ENIS_IN_SUBNET"

# for zsh
#eni_array=(${=ENIS_IN_SUBNET})

# for bash
read -a eni_array <<< "$(aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' \
  --output text)"

for eni in "${eni_array[@]}"; do
  echo "Disabling source/dest check on ENI: $eni"
  aws ec2 modify-network-interface-attribute \
    --region "$REGION" \
    --network-interface-id "$eni" \
    --source-dest-check "{\"Value\": false}"
done

echo "Step 5: Add ICMP and TCP 179 ingress rules to $TARGET_INSTANCE_NAME security group(s) and $SECURITY_GROUP_ID"
SG_IDS=$(aws ec2 describe-instances --region $REGION \
  --instance-ids "$TARGET_INSTANCE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[*].GroupId" \
  --output text)    

ecgho "Security Group IDs: $SG_IDS"

for sg in $SG_IDS; do
  echo " Adding ICMP rule to $sg"
  aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id "$sg" \
    --protocol icmp --port -1 --cidr 10.0.0.0/16 || echo " ICMP rule may already exist"

  echo " Adding TCP 179 rule to $sg"
  aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id "$sg" \
    --protocol tcp --port 179 --cidr 0.0.0.0/0 || echo " TCP 179 rule may already exist"
done

ecgho "Security Group IDs: $$SECURITY_GROUP_ID"
aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol icmp --port -1 --cidr 10.0.0.0/16 || echo " ICMP rule may already exist"

 aws ec2 authorize-security-group-ingress --region $REGION \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 179 --cidr 0.0.0.0/0 || echo " TCP 179 rule may already exist"


# Get public IP and private IP of the int-svc instance
PUBLIC_IP_INT_SVC=$( aws ec2 describe-instances \
 --instance-ids "$TARGET_INSTANCE_ID" \
 --region $REGION \
 --query "Reservations[*].Instances[*].PublicIpAddress" \
 --output text)
echo "public IP of instance $TARGET_INSTANCE_NAME: $PUBLIC_IP_INT_SVC"

PRIVATE_IP_INT_SVC=$( aws ec2 describe-instances \
 --instance-ids "$TARGET_INSTANCE_ID" \
 --region $REGION \
 --query "Reservations[*].Instances[*].PrivateIpAddress" \
 --output text)
echo "private IP of instance $TARGET_INSTANCE_NAME: $PRIVATE_IP_INT_SVC"

echo "All steps completed successfully!"
