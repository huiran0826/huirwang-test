
MASTER_NODE=$1
TAG=$2

function usage {

if [ $# != 2 ]
then
echo "usage: $0 master_node_name  ovs_tag"
echo "Example: fdp_deploy.sh sdn_master_node 127 "
fi
}



function build_image {

cat << EOF > Dockerfile
FROM registry-proxy.engineering.redhat.com/rh-osbs/openshift3-ose-node:v3.11
ADD  http://download.eng.bos.redhat.com/brewroot/vol/rhel-7/packages/openvswitch/2.9.0/${TAG}.el7fdp/x86_64/openvswitch-2.9.0-${TAG}.el7fdp.x86_64.rpm /tmp/
RUN yum install -y /tmp/*.rpm
EOF

hosts=$(ssh -i ~/.ssh/openshift-qe.pem root@${MASTER_NODE}  oc get nodes -o wide |awk '{print $6}' |sed '1d')

for host in ${hosts}
do
scp -i ~/.ssh/openshift-qe.pem Dockerfile root@${host}:/root
if [ $? == 0 ]
then
echo ""
ssh -i ~/.ssh/openshift-qe.pem root@${host} docker 'build -t registry-proxy.engineering.redhat.com/rh-osbs/openshift3-ose-node:v3.11.patched /root'
fi
done


if [ $? != 0 ]
then
echo "Docker build failed,exit;"
exit 1
fi

}

function patch_image{
echo "Start to patch image."
ssh -i ~/.ssh/openshift-qe.pem root@${MASTER_NODE} oc patch is node -n openshift-sdn -p \'[{"op": "replace", "path": "/spec/tags/0/from/name", "value": "registry-proxy.engineering.redhat.com/rh-osbs/openshift3-ose-node:v3.11.patched"}]\' --type json

if [ $? != 0 ] 
then
echo "patch failed,exit;"
exit 1
fi

echo "Patch image done!"
}

function restart_sdn_ovs_pod{
sleep 30
ssh -i ~/.ssh/openshift-qe.pem root@${MASTER_NODE} oc delete po --all -n openshift-sdn

sleep 10
ovs_pods=$(ssh -i ~/.ssh/openshift-qe.pem root@${MASTER_NODE} oc get po -l app=ovs -n openshift-sdn | awk '{print $1}'| sed '1d')
for ovs_pod in ${ovs_pods}
do
ssh -i ~/.ssh/openshift-qe.pem root@${MASTER_NODE} oc exec ${ovs_pod} -n openshift-sdn -- rpm -q openvswitch
done


if [ $? == 0 ] 
then
echo "patch completed!"
exit 0
fi
}

usage
build_image
patch_image
restart_sdn_ovs_pod


