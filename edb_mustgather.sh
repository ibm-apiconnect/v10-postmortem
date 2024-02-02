#!/bin/bash

# all logs collected are based off the EDB's troubleshooting guide
# https://docs.enterprisedb.io/cloud-native-postgresql/1.15.1/troubleshooting/#troubleshooting

# Confirm whether oc or kubectl exists and choose which command tool to use based on that
which oc &> /dev/null
if [[ $? -eq 0 ]]; then
    KUBECTL="oc"
else
    which kubectl &> /dev/null
    if [[ $? -ne 0 ]]; then
        echo "Unable to locate the command [kubectl] nor [oc] in the path.  Either install or add it to your PATH.  EXITING..."
        exit 1
    fi
    KUBECTL="kubectl"
fi

EDB_CLUSTER_NAMESPACE=$1
LOG_PATH=$2

if which kubectl-cnp >/dev/null; then
    echo kubectl-cnp plugin found
else
    echo kubectl-cnp plugin not found, please install it and add it to your PATH, see https://www.enterprisedb.com/docs/postgres_for_kubernetes/latest/kubectl-plugin
    exit 1
fi

if [ -z "$1" ] || [ -z "$2" ]
  then
    echo "USAGE: edb_mustgather.sh <edb-cluster-namespace> <log path>"
    echo "<edb-cluster-namespace>: Required - The namespace where the edb cluster is deployed in to"
    echo "<log path>: Required - The path where the edb must gather will be stored"
    exit 1
fi

EDB_OP_NAMESPACE=''
PG_OP=''
ARCHITECTURE=$($KUBECTL get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')

if [ "$ARCHITECTURE" = 's390x' ]; then
    EDB_OP_NAMESPACE='ibm-common-services'
    PG_OP=$($KUBECTL get po -n ${EDB_OP_NAMESPACE} -o=custom-columns=NAME:.metadata.name | grep postgresql-operator-controller-manager)
else
    EDB_OP_NAMESPACE=$EDB_CLUSTER_NAMESPACE
    PG_OP=$($KUBECTL get po -n ${EDB_OP_NAMESPACE} -o=custom-columns=NAME:.metadata.name | grep -e edb-operator -e postgresql-operator-controller-manager)
fi

MGMT_CR_NAME=$($KUBECTL get mgmt -n ${EDB_CLUSTER_NAMESPACE} -o=jsonpath='{.items[0].metadata.name}')
EDB_CLUSTER_NAME=$($KUBECTL get cluster -n ${EDB_CLUSTER_NAMESPACE} -o=jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'${MGMT_CR_NAME}'")].metadata.name}')
EDB_POD_NAMES=$($KUBECTL get pod -l k8s.enterprisedb.io/cluster=${EDB_CLUSTER_NAME} -n ${EDB_CLUSTER_NAMESPACE} -o=custom-columns=NAME:.metadata.name --no-headers)
EDB_BACKUP_NAMES=$($KUBECTL get backups -o=jsonpath='{.items[?(@.spec.cluster.name=="'${EDB_CLUSTER_NAME}'")]}' -n ${EDB_CLUSTER_NAMESPACE} -o=custom-columns=NAME:.metadata.name --no-headers)
K8S_DATA="${TEMP_PATH}/kubernetes"
K8S_NAMESPACES="${K8S_DATA}/namespaces"
K8S_NAMESPACES_SPECIFIC="${K8S_NAMESPACES}/${EDB_OP_NAMESPACE}"
K8S_NAMESPACES_EDB_DATA="${K8S_NAMESPACES_SPECIFIC}/edb"
K8S_NAMESPACES_POD_DATA="${K8S_NAMESPACES_SPECIFIC}/pods"
K8S_NAMESPACES_POD_DESCRIBE_DATA="${K8S_NAMESPACES_POD_DATA}/describe"
K8S_NAMESPACES_POD_LOG_DATA="${K8S_NAMESPACES_POD_DATA}/logs"
NS=${LOG_PATH}/namespaces
SPECIFIC_NS_EDB_OP=${NS}/${EDB_OP_NAMESPACE}
SPECIFIC_NS_CLUSTER=${NS}/${EDB_CLUSTER_NAMESPACE}
OPERATOR_PODS=${SPECIFIC_NS_EDB_OP}/pods
CLUSTER=${SPECIFIC_NS_CLUSTER}/cluster
CLUSTER_PODS=${SPECIFIC_NS_CLUSTER}/pods
CLUSTER_BACKUPS=${SPECIFIC_NS_CLUSTER}/backups


mkdir ${NS}
mkdir ${SPECIFIC_NS_EDB_OP}
mkdir -p ${SPECIFIC_NS_CLUSTER}
mkdir ${OPERATOR_PODS}
mkdir ${CLUSTER}
mkdir ${CLUSTER}/${EDB_CLUSTER_NAME}
mkdir -p ${CLUSTER_PODS}
mkdir ${CLUSTER_BACKUPS}
mkdir ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}

function gatherEdbOperatorData() {
    $KUBECTL cnp report operator --logs -n ${EDB_OP_NAMESPACE} -f ${SPECIFIC_NS_EDB_OP}/operator-report.zip

    for pod in $PG_OP
    do
        mkdir ${OPERATOR_PODS}/${pod}
        $KUBECTL get po ${pod} -o yaml -n ${EDB_OP_NAMESPACE} > ${OPERATOR_PODS}/${pod}/pod.yaml
        $KUBECTL describe pod ${pod} -n ${EDB_OP_NAMESPACE} > ${OPERATOR_PODS}/${pod}/describe.txt
        $KUBECTL logs ${pod} -n ${EDB_OP_NAMESPACE} > ${OPERATOR_PODS}/${pod}/logs.txt
        $KUBECTL logs ${pod} -n ${EDB_OP_NAMESPACE} --previous 2>/dev/null > ${OPERATOR_PODS}/${pod}/previous-logs.txt
    done
}

function gatherClusterData() {
    $KUBECTL cnp status ${EDB_CLUSTER_NAME} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/status.txt
    $KUBECTL cnp status ${EDB_CLUSTER_NAME} --verbose -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/status-verbose.txt

    $KUBECTL get cluster -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/info.txt
    $KUBECTL get cluster -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/cluster.yaml
    $KUBECTL describe cluster -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/describe.txt

}

function gatherEDBPodData() {
    $KUBECTL cnp report cluster ${EDB_CLUSTER_NAME} --logs -n ${EDB_CLUSTER_NAMESPACE} -f ${SPECIFIC_NS_CLUSTER}/cluster-report.zip

    $KUBECTL get pod -l k8s.enterprisedb.io/cluster=${EDB_CLUSTER_NAME} -L role -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/pods.txt
    for pod in ${EDB_POD_NAMES}; do
        mkdir ${CLUSTER_PODS}/${pod}
        $KUBECTL get po ${pod} -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/${pod}/pod.yaml
        $KUBECTL describe pod ${pod} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/${pod}/describe.txt
        $KUBECTL logs ${pod} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/${pod}/logs.txt
        $KUBECTL logs ${pod} -n ${EDB_CLUSTER_NAMESPACE} --previous 2>/dev/null > ${CLUSTER_PODS}/${pod}/previous-logs.txt
        $KUBECTL logs ${pod} -n ${EDB_CLUSTER_NAMESPACE} | jq -r '.record | select(.error_severity == "FATAL")' > ${CLUSTER_PODS}/${pod}/logs-fatal.txt
    done
}

function gatherEDBBackupData() {
    $KUBECTL get backups -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/backups.txt
    for backup in ${EDB_BACKUP_NAMES}; do
        mkdir ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}
        $KUBECTL get backups ${backup} -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}/backup.yaml
        $KUBECTL describe backups ${backup} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}/describe.txt
    done
}



if [[ -z "$PG_OP" ]]; then
    echo "failed to find the edb operator in the ${EDB_OP_NAMESPACE} namespace, could be in a different namespace"
else
   gatherEdbOperatorData
fi

if [[ -z "$EDB_CLUSTER_NAME" ]]; then
    echo "failed to find the edb cluster in the ${EDB_CLUSTER_NAMESPACE} namespace"
    exit 1
else
   gatherClusterData
fi

if [[ -z "$EDB_POD_NAMES" ]]; then
    echo "failed to find the edb cluster pods in the ${EDB_CLUSTER_NAMESPACE} namespace"
    exit 1
else
   gatherEDBPodData
fi

if [[ -z "$EDB_BACKUP_NAMES" ]]; then
    echo "failed to find the edb cluster backups in the ${EDB_CLUSTER_NAMESPACE} namespace"
else
   gatherEDBBackupData
fi
