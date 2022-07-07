#!/bin/bash

# all logs collected are based off the EDB's troubleshooting guide
# https://docs.enterprisedb.io/cloud-native-postgresql/1.15.1/troubleshooting/#troubleshooting

EDB_CLUSTER_NAMESPACE=$1
LOG_PATH=$2

if which kubectl-cnp >/dev/null; then
    echo kubectl-cnp plugin found
else
    echo kubectl-cnp plugin not found, please install it from here https://www.enterprisedb.com/docs/postgres_for_kubernetes/latest/cnp-plugin
    exit 1
fi

if [ -z "$1" ] || [ -z "$2" ]
  then
    echo "USAGE: edb_mustgather.sh <edb-cluster-namespace> <log path>"
    echo "<edb-cluster-namespace>: Required - The namespace where the edb cluster is deployed in to"
    echo "<log path>: Required - The path where the edb must gather will be stored"
    exit 1
fi

EDB_OP_NAMESPACE='ibm-common-services'
PG_OP=$(oc get po -n ${EDB_OP_NAMESPACE} -o=custom-columns=NAME:.metadata.name | grep postgresql-operator-controller-manager)
EDB_CLUSTER_NAME=$(oc get cluster -n ${EDB_CLUSTER_NAMESPACE} -o=jsonpath='{.items[0].metadata.name}')
EDB_POD_NAMES=$(kubectl get pod -l k8s.enterprisedb.io/cluster=${EDB_CLUSTER_NAME} -L role -n ${EDB_CLUSTER_NAMESPACE} -o=custom-columns=NAME:.metadata.name --no-headers)
EDB_BACKUP_NAMES=$(kubectl get backups -l k8s.enterprisedb.io/cluster=${EDB_CLUSTER_NAME} -L role -n ${EDB_CLUSTER_NAMESPACE} -o=custom-columns=NAME:.metadata.name --no-headers)
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
PO=${SPECIFIC_NS_EDB_OP}/pods
CLUSTER=${SPECIFIC_NS_CLUSTER}/cluster
CLUSTER_PODS=${SPECIFIC_NS_CLUSTER}/pods
CLUSTER_BACKUPS=${SPECIFIC_NS_CLUSTER}/backups


mkdir ${NS}
mkdir ${SPECIFIC_NS_EDB_OP}
mkdir ${SPECIFIC_NS_CLUSTER}
mkdir ${PO}
mkdir ${PO}/${PG_OP}
mkdir ${CLUSTER}
mkdir ${CLUSTER}/${EDB_CLUSTER_NAME}
mkdir ${CLUSTER_PODS}
mkdir ${CLUSTER_BACKUPS}
mkdir ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}

function gatherEdbOperatorData() {
    kubectl describe pod ${PG_OP} -n ${EDB_OP_NAMESPACE} > ${PO}/${PG_OP}/describe.txt
    kubectl logs ${PG_OP} -n ${EDB_OP_NAMESPACE} > ${PO}/${PG_OP}/logs.txt
}

function gatherClusterData() {
    kubectl cnp status ${EDB_CLUSTER_NAME} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/status.txt
    kubectl cnp status ${EDB_CLUSTER_NAME} --verbose -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/status-verbose.txt
    kubectl get cluster -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/info.txt
    kubectl get cluster -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/cluster.yaml
    kubectl describe cluster -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/describe.txt

}

function gatherEDBPodData() {
    kubectl get pod -l k8s.enterprisedb.io/cluster=${EDB_CLUSTER_NAME} -L role -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/pods.txt
    for pod in ${EDB_POD_NAMES}; do
        mkdir ${CLUSTER_PODS}/${pod} 
        kubectl get po ${pod} -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/${pod}/pod.yaml
        kubectl describe pod ${pod} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/${pod}/describe.txt
        kubectl logs ${pod} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_PODS}/${pod}/logs.txt
        kubectl logs ${pod} -n ${EDB_CLUSTER_NAMESPACE} --previous 2>/dev/null > ${CLUSTER_PODS}/${pod}/previous-logs.txt
        kubectl logs ${pod} -n ${EDB_CLUSTER_NAMESPACE} | jq -r '.record | select(.error_severity == "FATAL")' > ${CLUSTER_PODS}/${pod}/logs-fatal.txt
    done
}

function gatherEDBBackupData() {
    kubectl get backups -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/backups.txt
    for backup in ${EDB_BACKUP_NAMES}; do
        mkdir ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup} 
        kubectl get backups ${backup} -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}/backup.yaml
        kubectl describe backups ${backup} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}/describe.txt
    done
}



if [[ -z "$PG_OP" ]]; then
    echo "failed to find the edb operator in the ${EDB_OP_NAMESPACE} namespace"
    exit 1
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