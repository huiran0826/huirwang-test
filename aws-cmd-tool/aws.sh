export NODE_IP_NAME="ip-10-0-48-110.us-east-2.compute.internal"
export REGION="us-east-2" 
export TARGET_INSTANCE_NAME="bgp-0813-int-svc"
KEY_FILE="/Users/huirwang/.ssh/openshift-qe.pem"  # Path to your SSH key
USER="core"
REMOTE_PATH="/var/home/core"
LOCAL_KUBECONFIG_PATH="/tmp/kubeconfig"
KUBECONFIG_REMOTE="$REMOTE_PATH/kubeconfig"
SCRIPT_NAME="generate_external_frr.sh" 

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

echo "External instance was configured completely"
echo "Start to setup frr in external instance"

cat << 'FRR_SCRIPT' > $SCRIPT_NAME
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


generate_frr_config() {
    local NODE="$1"  # Get NODE argument
    local OUTPUT_FILE="$2"  # Get output file path argument
    local IFS=' '
    read -ra ips <<< "$NODE"
    local ipv4_list=()
    
    # First filter out IPv4 addresses
    for ip in "${ips[@]}"; do
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ipv4_list+=("$ip")
        fi
    done

    # Write to file using heredoc
    cat > "$OUTPUT_FILE" << EOF
router bgp 64512
 no bgp default ipv4-unicast
 no bgp network import-check

EOF

    # Generate neighbor remote-as section
    for ip in "${ipv4_list[@]}"; do
        echo " neighbor $ip remote-as 64512" >> "$OUTPUT_FILE"
    done
    echo "" >> "$OUTPUT_FILE"

    echo " address-family ipv4 unicast" >> "$OUTPUT_FILE"
    echo "  network 172.20.100.0/24" >> "$OUTPUT_FILE"
    for ip in "${ipv4_list[@]}"; do
        echo "  neighbor $ip activate" >> "$OUTPUT_FILE"
        echo "  neighbor $ip next-hop-self" >> "$OUTPUT_FILE"
        echo "  neighbor $ip route-reflector-client" >> "$OUTPUT_FILE"
    done
    echo " exit-address-family" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

}
generate_daemons() {
local FILE_NAME="$1"
cat > "$FILE_NAME" << EOF
# This file tells the frr package which daemons to start.
#
# Sample configurations for these daemons can be found in
# /usr/share/doc/frr/examples/.
#
# ATTENTION:
#
# When activating a daemon for the first time, a config file, even if it is
# empty, has to be present *and* be owned by the user and group "frr", else
# the daemon will not be started by /etc/init.d/frr. The permissions should
# be u=rw,g=r,o=.
# When using "vtysh" such a config file is also needed. It should be owned by
# group "frrvty" and set to ug=rw,o= though. Check /etc/pam.d/frr, too.
#
# The watchfrr and zebra daemons are always started.
#
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=yes
fabricd=no
vrrpd=no

#
# If this option is set the /etc/init.d/frr script automatically loads
# the config via "vtysh -b" when the servers are started.
# Check /etc/pam.d/frr if you intend to use "vtysh"!
#
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
ospfd_options="  -A 127.0.0.1"
ospf6d_options=" -A ::1"
ripd_options="   -A 127.0.0.1"
ripngd_options=" -A ::1"
isisd_options="  -A 127.0.0.1"
pimd_options="   -A 127.0.0.1"
ldpd_options="   -A 127.0.0.1"
nhrpd_options="  -A 127.0.0.1"
eigrpd_options=" -A 127.0.0.1"
babeld_options=" -A 127.0.0.1"
sharpd_options=" -A 127.0.0.1"
pbrd_options="   -A 127.0.0.1"
staticd_options="-A 127.0.0.1"
bfdd_options="   -A 127.0.0.1"
fabricd_options="-A 127.0.0.1"
vrrpd_options="  -A 127.0.0.1"

# configuration profile
#
#frr_profile="traditional"
#frr_profile="datacenter"

#
# This is the maximum number of FD's that will be available.
# Upon startup this is read by the control files and ulimit
# is called. Uncomment and use a reasonable value for your
# setup if you are expecting a large number of peers in
# say BGP.
#MAX_FDS=1024

# The list of daemons to watch is automatically generated by the init script.
#watchfrr_options=""

# for debugging purposes, you can specify a "wrap" command to start instead
# of starting the daemon directly, e.g. to use valgrind on ospfd:
#   ospfd_wrap="/usr/bin/valgrind"
# or you can use "all_wrap" for all daemons, e.g. to use perf record:
#   all_wrap="/usr/bin/perf record --call-graph -"
# the normal daemon command is added to this at the end.

EOF
}


  
  export KUBECONFIG=/var/home/core/kubeconfig
  ip addr add 172.20.100.1/24 dev eth1
  oc patch Network.operator.openshift.io cluster --type=merge -p='{"spec":{"additionalRoutingCapabilities": {"providers": ["FRR"]}, "defaultNetwork":{"ovnKubernetesConfig":{"routeAdvertisements":"Enabled"}}}}'
  NODES=$(kubectl get nodes -o jsonpath={.items[*].status.addresses[?\(@.type==\"InternalIP\"\)].address})
  echo $NODES
  rm -rf /root/frr-ext
  mkdir /root/frr-ext
  cd /root/frr-ext
  generate_daemons /root/frr-ext/daemons
  generate_frr_config "$NODES" /root/frr-ext/frr.conf
  
  sudo podman run -d --privileged --network host --rm --ulimit core=-1 --name frr --volume /root/frr-ext:/etc/frr quay.io/frrouting/frr:9.1.2

FRR_SCRIPT

# ---- Step 1: SCP kubeconfig and script ----
echo "Copying kubeconfig and script to remote host..."
scp -i "$KEY_FILE" -o StrictHostKeyChecking=no $LOCAL_KUBECONFIG_PATH "$SCRIPT_NAME" "$USER@$PUBLIC_IP_INT_SVC:$REMOTE_PATH"

# ---- Step 2: Set KUBECONFIG and run the script remotely ----
echo "Running script on remote host..."
ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no "$USER@$PUBLIC_IP_INT_SVC" << EOF
  export KUBECONFIG="$KUBECONFIG_REMOTE"
  sudo chmod +x "$REMOTE_PATH/$SCRIPT_NAME"
  sudo "$REMOTE_PATH/$SCRIPT_NAME"
EOF

# wait ovn pods rollout
sleep 120

# 
oc apply -f - <<EOF
apiVersion: frrk8s.metallb.io/v1beta1
kind: FRRConfiguration
metadata:
  name: receive-all
  namespace: openshift-frr-k8s
spec:
  bgp:
    routers:
    - asn: 64512
      neighbors:
      - address: ${PRIVATE_IP_INT_SVC}
        disableMP: true
        asn: 64512
        toReceive:
          allowed:
            mode: all
EOF

echo "All steps completed successfully!"
