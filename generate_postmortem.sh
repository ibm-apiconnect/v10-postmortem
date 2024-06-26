#!/bin/bash
#
# Purpose: Collects API Connect logs and packages into an archive.
#
# Authors:        Charles Johnson, cjohnso@us.ibm.com
#                 Franck Delporte, franck.delporte@us.ibm.com
#                 Nagarjun Nama Balaji, nagarjun.nama.balaji@ibm.com
#                 Kenny Nguyen, kennyqn@ibm.com
#

#parse passed arguments
NUMERICALVERSION=44
PMCOMMITDATE='Thu Apr 11 04:31:36 UTC 2024'
PMCOMMIT='51fdde0f23c6e63270dedc6d7aa721cb27a8412f'
PMCOMMITURL="https://github.com/ibm-apiconnect/v10-postmortem/blob/$PMCOMMIT/generate_postmortem.sh"
print_postmortem_version(){
    echo "Postmortem Version: $NUMERICALVERSION, Date: $PMCOMMITDATE, URL: $PMCOMMITURL"
}

# We want customers to use the latest postmortem scripts wherever possible
warn_if_script_is_not_latest() {
    if [[ ${NO_SCRIPT_CHECK:-0} -eq 1 ]]; then
        return
    fi

    local script_name=$1
    local script_remote_url=$2

    local_script_hash=$(sha256sum "$script_name" | cut -d ' ' -f1)
    response=$(curl -s --connect-timeout 5 "$script_remote_url") && rc=$? || rc=$?
    # Only give the warning if we know this was a good returned hash
    if [[ "$rc" -eq 0 ]]; then
        remote_script_hash=$(echo "$response" | sha256sum | cut -d ' ' -f1) || true
        if [[ -n "$remote_script_hash" && ${#remote_script_hash} -eq 64 && "$remote_script_hash" != "$local_script_hash" ]]; then
            echo "---------------------------------------------------------"
            echo "NOTE: There is a newer version of $script_name available. Please download the latest postmortem script from https://github.com/ibm-apiconnect/v10-postmortem so that up-to-date information is gathered."
            echo "WARNING: If you don't use the latest $script_name script, IBM support may ask you to download the latest $script_name script and run it again."
            echo "---------------------------------------------------------"
        fi
    fi
}

#Confirm whether oc or kubectl exists and choose which command tool to use based on that
which oc &> /dev/null
if [[ $? -eq 0 ]]; then
    KUBECTL="oc"
    $KUBECTL whoami
    if [[ $? -ne 0 ]]; then
      echo "Error: oc whoami failed. This script requires you to be logged in to the server. EXITING..."
      exit 1
    fi
else
    which kubectl &> /dev/null
    if [[ $? -ne 0 ]]; then
        echo "Unable to locate the command [kubectl] nor [oc] in the path.  Either install or add it to the path.  EXITING..."
        exit 1
    fi
    KUBECTL="kubectl"
fi

# Check if kubectl-cnp plugin is installed
function is_kubectl_cnp_plugin {
    if which kubectl-cnp >/dev/null; then
        echo kubectl-cnp plugin found
    else
        echo -e "kubectl-cnp plugin not found"
        read -p "Download and Install kubectl-cnp plugin (y/n)? " yn
        case $yn in
            [Yy]* )
                echo -e "Proceeding..."
                echo -e "Executing: curl -sSfL https://github.com/EnterpriseDB/kubectl-cnp/raw/main/install.sh | sudo sh -s -- -b /usr/local/bin"
                curl -sSfL \
                    https://github.com/EnterpriseDB/kubectl-cnp/raw/main/install.sh | \
                    sudo sh -s -- -b /usr/local/bin
                if [[ $? -ne 0 ]]; then
                    echo "Error installing kubectl-cnp plugin. Exiting..."
                    exit 1
                fi
                ;;
            [Nn]* )
                echo -e "Exiting... please install kubectl-cnp plugin and add it to your PATH, see https://www.enterprisedb.com/docs/postgres_for_kubernetes/latest/kubectl-plugin."
                exit 1
                ;;
        esac
    fi
}

#Check to see if this is an OCP cluster
IS_OCP=false
if $KUBECTL api-resources | grep -q "route.openshift.io"; then
    IS_OCP=true
fi

for switch in $@; do
    case $switch in
        *"-h"*|*"--help"*)
            echo -e 'Usage: generate_postmortem.sh {optional: LOG LIMIT}'
            echo -e ""
            echo -e "Available switches:"
            echo -e ""
            echo -e "--specific-namespaces:     Target only the listed namespaces for the data collection.  Example:  --specific-namespaces=dev1,dev2,dev3"
            echo -e "--extra-namespaces:        Extra namespaces separated with commas.  Example:  --extra-namespaces=dev1,dev2,dev3"
            echo -e "--log-limit:               Set the number of lines to collect from each pod logs."
            echo -e "--no-prompt:               Do not prompt to report auto-detected namespaces."
            echo -e "--performance-check:       Set to run performance checks."
            echo -e "--no-history:              Do not collect user history."
            echo -e ""
            echo -e "--ova:                     Only set if running inside an OVA deployment."
            echo -e ""
            echo -e "--collect-private-keys:    Include "tls.key" members in TLS secrets from targeted namespaces.  Due to sensitivity of data, do not use unless requested by support."
            echo -e "--collect-crunchy:         Collect Crunchy mustgather."
            echo -e "--collect-edb:             Collect EDB mustgather."
            echo -e ""
            echo -e "--no-diagnostic:           Set to disable all diagnostic data."
            echo -e "--no-manager-diagnostic:   Set to disable additional manager specific data."
            echo -e "--no-gateway-diagnostic:   Set to disable additional gateway specific data."
            echo -e "--no-portal-diagnostic:    Set to disable additional portal specific data."
            echo -e "--no-analytics-diagnostic: Set to disable additional analytics specific data."
            echo -e ""
            echo -e "--debug:                   Set to enable verbose logging."
            echo -e "--no-script-check:         Set to disable checking if the postmortem scripts are up to date."
            echo -e ""
            echo -e "--version:                 Show postmortem version"
            exit 0
            ;;
        *"--debug"*)
            set -x
            DEBUG_SET=1
            ;;
        *"--ova"*)
            if [[ $EUID -ne 0 ]]; then
                echo "This script must be run as root."
                exit 1
            fi

            IS_OVA=1
            NO_PROMPT=1
            NAMESPACE_LIST="kube-system"
            ;;
        *"--no-diagnostic"*)
            NOT_DIAG_MANAGER=1
            NOT_DIAG_GATEWAY=1
            NOT_DIAG_PORTAL=1
            NOT_DIAG_ANALYTICS=1
            ;;
        *"--no-manager-diagnostic"*)
            NOT_DIAG_MANAGER=1
            ;;
        *"--no-gateway-diagnostic"*)
            NOT_DIAG_GATEWAY=1
            ;;
        *"--no-portal-diagnostic"*)
            NOT_DIAG_PORTAL=1
            ;;
        *"--no-analytics-diagnostic"*)
            NOT_DIAG_ANALYTICS=1
            ;;
        *"--log-limit"*)
            limit=`echo "${switch}" | cut -d'=' -f2`
            if [[ "$limit" =~ ^[0-9]+$ ]]; then
                LOG_LIMIT="--tail=${limit}"
            fi
            ;;
        *"--specific-namespaces"*)
            NO_PROMPT=1
            SPECIFIC_NAMESPACES=1
            specific_namespaces=`echo "${switch}" | cut -d'=' -f2 | tr ',' ' '`
            NAMESPACE_LIST="${specific_namespaces}"
            AUTO_DETECT=0
            ;;
        *"--extra-namespaces"*)
            NO_PROMPT=1
            extra_namespaces=`echo "${switch}" | cut -d'=' -f2 | tr ',' ' '`
            NAMESPACE_LIST="kube-system ${extra_namespaces}"
            ;;
        *"--performance-check"*)
            PERFORMANCE_CHECK=1
            ;;
        *"--no-history"*)
            NO_HISTORY=1
            ;;
        *"--no-prompt"*)
            NO_PROMPT=1
            ;;
        *"--no-script-check"*)
            NO_SCRIPT_CHECK=1
            ;;
        *"--collect-private-keys"*)
            COLLECT_PRIVATE_KEYS=1
            ;;
        *"--collect-crunchy"*)
            COLLECT_CRUNCHY=1
            ;;
        *"--collect-edb"*)
            COLLECT_EDB=1
            is_kubectl_cnp_plugin
            ;;
        *"--version"*)
            print_postmortem_version
            exit 0
            ;;
        *)
            if [[ -z "$DEBUG_SET" ]]; then
                set +e
            fi
            ;;
    esac
done

echo -e "#\n# WARNING: this script is being deprecated in favor of the apic-mustgather tool."
echo -e "# Please see: https://github.com/ibm-apiconnect/v10-postmortem"
echo -e "#"

#Printing Postmortem Version
print_postmortem_version
echo "using [$KUBECTL] command for cluster cli"

warn_if_script_is_not_latest ${0##*/} "https://raw.githubusercontent.com/ibm-apiconnect/v10-postmortem/master/generate_postmortem.sh"

if [[ -z "$LOG_LIMIT" ]]; then
    LOG_LIMIT=""
fi

if [[ -z "$NO_PROMPT" ]]; then
    NO_PROMPT=0
fi

if [[ -z "$SPECIFIC_NAMESPACES" ]]; then
    SPECIFIC_NAMESPACES=0
fi

#====================================== Confirm pre-reqs and init variables ======================================
#------------------------------- Make sure all necessary commands exists ------------------------------

ARCHIVE_UTILITY=`which zip 2>/dev/null`
if [[ $? -ne 0 ]]; then
    ARCHIVE_UTILITY=`which tar 2>/dev/null`
    if [[ $? -ne 0 ]]; then
        echo "Unable to locate either command [tar] / [zip] in the path.  Either install or add it to the path.  EXITING..."
        exit 1
    fi
fi

if [[ $NOT_DIAG_MANAGER -eq 0 ]]; then
    EDB_CLUSTER_NAME=$($KUBECTL get cluster --all-namespaces -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$EDB_CLUSTER_NAME" ]]; then
        COLLECT_CRUNCHY=1
    else
        COLLECT_EDB=1
        is_kubectl_cnp_plugin
    fi
fi

which apicops &> /dev/null
if [[ $? -eq 0 ]]; then
    APICOPS="apicops"
else
    if [[ ! -e /tmp/apicops-v10-linux  ]]; then
        if [[ $NO_PROMPT -eq 0 ]]; then
            echo -e "apicops cli not found!"
            read -p "Download and Install apicops cli (y/n)? " yn
            case $yn in
                [Yy]* )
                    echo -e "Downloading apicops......"
                    curl -L -o /tmp/apicops-v10-linux https://github.com/ibm-apiconnect/apicops/releases/latest/download/apicops-v10-linux
                    if [[ ! -e /tmp/apicops-v10-linux  ]]; then
                        echo -e "Warning: Failed to download the apicops cli. Skipping to collect apicops mustgather. Please download the latest release of apicops manually before running the postmortem script. commands: curl -LO https://github.com/ibm-apiconnect/apicops/releases/latest/download/apicops-v10-linux"
                    else
                        chmod +x /tmp/apicops-v10-linux
                        APICOPS="/tmp/apicops-v10-linux"
                    fi
                    ;;
                [Nn]* )
                    echo -e "Skipping to collect apicops mustgather"
                    ;;
            esac
        else
            echo -e "Skipping to collect apicops mustgather"
        fi
    else
        APICOPS="/tmp/apicops-v10-linux"
    fi
fi
#------------------------------------------------------------------------------------------------------

#------------------------------------------ custom functions ------------------------------------------
#compare versions
function version_gte() { test "$1" == "$2" || test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

#XML to generate error report
function generateXmlForErrorReport()
{
cat << EOF > $1
<?xml version="1.0" encoding="UTF-8"?>
<!--  ErrorReport Request -->
<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
  <env:Body>
    <dp:request xmlns:dp="http://www.datapower.com/schemas/management" domain="default">
      <dp:do-action>
        <ErrorReport/>
      </dp:do-action>
    </dp:request>
  </env:Body>
</env:Envelope>
EOF
}

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

    $KUBECTL get cluster ${EDB_CLUSTER_NAME} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/info.txt
    $KUBECTL get cluster ${EDB_CLUSTER_NAME} -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/cluster.yaml
    $KUBECTL describe cluster ${EDB_CLUSTER_NAME} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER}/${EDB_CLUSTER_NAME}/describe.txt

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
    $KUBECTL get backups -n ${EDB_CLUSTER_NAMESPACE} -o=jsonpath='{.items[?(@.spec.cluster.name=="'${EDB_CLUSTER_NAME}'")]}' -o wide > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/backups.txt
    for backup in ${EDB_BACKUP_NAMES}; do
        mkdir ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}
        $KUBECTL get backups ${backup} -o yaml -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}/backup.yaml
        $KUBECTL describe backups ${backup} -n ${EDB_CLUSTER_NAMESPACE} > ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}/${backup}/describe.txt
    done
}

function gatherEDBScheduledBackupData() {
    $KUBECTL -n ${EDB_CLUSTER_NAMESPACE} get scheduledbackups -o=jsonpath='{.items[?(@.spec.cluster.name=="'${EDB_CLUSTER_NAME}'")]}' -o wide > ${CLUSTER_SCHEDULED_BACKUPS}/${EDB_CLUSTER_NAME}/scheduledbackups.txt
    for scheduledbackup in ${EDB_SCHEDULED_BACKUP_NAMES}; do
        mkdir ${CLUSTER_SCHEDULED_BACKUPS}/${EDB_CLUSTER_NAME}/${scheduledbackup}
        $KUBECTL -n ${EDB_CLUSTER_NAMESPACE} get scheduledbackups ${scheduledbackup} -o yaml > ${CLUSTER_SCHEDULED_BACKUPS}/${EDB_CLUSTER_NAME}/${scheduledbackup}/backup.yaml
        $KUBECTL -n ${EDB_CLUSTER_NAMESPACE} describe scheduledbackups ${scheduledbackup} > ${CLUSTER_SCHEDULED_BACKUPS}/${EDB_CLUSTER_NAME}/${scheduledbackup}/describe.txt
    done
}

function collectEDB {
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

  MGMT_CR_NAME=$($KUBECTL get mgmt -n ${EDB_CLUSTER_NAMESPACE} -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  EDB_CLUSTER_NAME=$($KUBECTL get cluster -n ${EDB_CLUSTER_NAMESPACE} -o=jsonpath='{.items[?(@.metadata.ownerReferences[0].name=="'${MGMT_CR_NAME}'")].metadata.name}' 2>/dev/null)
  EDB_POD_NAMES=$($KUBECTL get pod -l k8s.enterprisedb.io/cluster=${EDB_CLUSTER_NAME} -L role -n ${EDB_CLUSTER_NAMESPACE} -o=custom-columns=NAME:.metadata.name --no-headers)
  EDB_BACKUP_NAMES=$($KUBECTL get backups -o=jsonpath='{.items[?(@.spec.cluster.name=="'${EDB_CLUSTER_NAME}'")]}' -L role -n ${EDB_CLUSTER_NAMESPACE} -o=custom-columns=NAME:.metadata.name --no-headers)
  EDB_SCHEDULED_BACKUP_NAMES=$($KUBECTL get scheduledBackups -o=jsonpath='{.items[?(@.spec.cluster.name=="'${EDB_CLUSTER_NAME}'")]}' -n ${EDB_CLUSTER_NAMESPACE} -o=custom-columns=NAME:.metadata.name --no-headers)
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
  CLUSTER_SCHEDULED_BACKUPS=${SPECIFIC_NS_CLUSTER}/scheduledbackups


  mkdir ${NS}
  mkdir ${SPECIFIC_NS_EDB_OP}
  mkdir -p ${SPECIFIC_NS_CLUSTER}
  mkdir ${OPERATOR_PODS}
  mkdir ${CLUSTER}
  mkdir -p ${CLUSTER}/${EDB_CLUSTER_NAME}
  mkdir -p ${CLUSTER_PODS}
  mkdir ${CLUSTER_BACKUPS}
  mkdir -p ${CLUSTER_BACKUPS}/${EDB_CLUSTER_NAME}
  mkdir ${CLUSTER_SCHEDULED_BACKUPS}
  mkdir -p ${CLUSTER_SCHEDULED_BACKUPS}/${EDB_CLUSTER_NAME}

  if [[ -n "$PG_OP" ]]; then
    echo "Found EDB operator pod $PG_OP"
    gatherEdbOperatorData
  fi

  if [[ -n "$EDB_CLUSTER_NAME" ]]; then
    echo "Found EDB Cluster $EDB_CLUSTER_NAME"
    gatherClusterData
  fi

  if [[ -n "$EDB_POD_NAMES" ]]; then
    gatherEDBPodData
  fi

  if [[ -n "$EDB_BACKUP_NAMES" ]]; then
    gatherEDBBackupData
  fi

  if [[ -n "$EDB_SCHEDULED_BACKUP_NAMES" ]]; then
    gatherEDBScheduledBackupData
  fi
}

function collectCrunchy {
  python3 - << EOF -n $NAMESPACE -l 7 -c $KUBECTL -o $K8S_NAMESPACES_CRUNCHY_DATA &> "${K8S_NAMESPACES_CRUNCHY_DATA}/crunchy-collect.log"
"""
Copyright 2017 - 2021 Crunchy Data
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Crunchy kubernetes support dump script

Original Author: Pramodh Mereddy <pramodh.mereddy@crunchydata.com>

Description:
    This script collects kubernetes objects, logs and other metadata from
    the objects corresponding to Crunchydata container solution
    NOTE: secrets are data are NOT collected

Pre-requisites:
    1. Valid login session to your kubernetes cluster
    2. kubectl or oc CLI in your PATH

Example:
    ./crunchy_gather_k8s_support_dump.py -n pgdb -o $HOME/dumps/crunchy/pgdb

Arguments:
    -n: namespace or project name
    -o: directory to create the support dump in
    -l: number of pg_log files to save
"""

import argparse
import logging
import os
import subprocess
import sys
import tarfile
import posixpath
import time
from collections import OrderedDict

if sys.version_info[0] < 3:
    print("Python 3 or a more recent version is required.")
    sys.exit()

# Local Script Version
# Update for each release
__version__ = "v1.0.2"


class Options():  # pylint: disable=too-few-public-methods
    """
        class for globals
    """
    def __init__(self, dest_dir, namespace, kube_cli, pg_logs_count):
        self.dest_dir = dest_dir
        self.namespace = namespace
        self.kube_cli = kube_cli
        self.pg_logs_count = pg_logs_count
        self.delete_dir = False
        self.output_dir = ""
        self.dir_name = (f"crunchy_{time.strftime('%Y-%m-%d-%H%M%S')}")


OPT = Options("", "", "kubectl", 2)


MAX_ARCHIVE_EMAIL_SIZE = 25*1024*1024  # 25 MB filesize limit
logger = logging.getLogger("crunchy_support")  # pylint: disable=locally-disabled, invalid-name

API_RESOURCES = [
    "pods",
    "ReplicaSet",
    "StatefulSet",
    "Deployment",
    "Services",
    "Routes",
    "Ingress",
    "pvc",
    "configmap",
    "networkpolicies",
    "postgresclusters",
    "pgreplicas",
    "pgclusters",
    "pgpolicies",
    "pgtasks"
]

CONTAINER_COMMANDS = {
    'collect': [],
    'exporter': [],
    'database': ["patronictl list", "patronictl history"],
    'pgbadger': [],
    'pgbackrest': [],
    'replication-cert-copy': [],
    'all': ["ps aux --width 500"]
}


def run():
    """
        Main function to collect support dump
    """

    logger.info("Saving support dump files in %s", OPT.output_dir)

    collect_current_time()
    collect_script_version()
    collect_kube_version()
    collect_node_info()
    collect_namespace_info()
    collect_events()
    collect_pvc_list()
    collect_configmap_list()
    collect_pods_describe()
    collect_api_resources()
    collect_pg_logs()
    collect_pods_logs()
    collect_pg_pod_details()
    archive_files()


def collect_current_time():
    """
        function to collect the time which the Support Dump was
        captured, so that Events and other relative-time items could
        be easily correlated
    """
    cmd = "date"
    logger.debug("collecting current timestamp info: %s", cmd)
    collect_helper(cmd, file_name="timestamp.info", resource_name="timestamp info")


def collect_kube_version():
    """
        function to gather kubernetes version information
    """
    cmd = OPT.kube_cli + " version "
    logger.debug("collecting kube version info: %s", cmd)
    collect_helper(cmd, file_name="k8s-version.info", resource_name="Platform Version info")


def collect_script_version():
    """
        function to gather script version, allow us to determine
        if the tool is out of date
    """
    cmd = "echo Support Dump Tool: " + __version__
    logger.debug("collecting support dump tool version info: %s", cmd)
    collect_helper(cmd, file_name="dumptool-version.info", resource_name="Support Dump Tool version info")


def collect_node_info():
    """
        function to gather kubernetes node information
    """
    cmd = OPT.kube_cli + " get nodes -o wide "
    logger.debug("collecting node info: %s", cmd)
    collect_helper(cmd, file_name="nodes.info", resource_name="Node info")


def collect_namespace_info():
    """
        function to gather kubernetes namespace information
    """
    if OPT.kube_cli == "oc":
        cmd = OPT.kube_cli + " describe project " + OPT.namespace
    else:
        cmd = OPT.kube_cli + " get namespace -o yaml " + OPT.namespace

    logger.debug("collecting namespace info: %s", cmd)
    collect_helper(cmd, file_name="namespace.yml",
                   resource_name="namespace-info")


def collect_pvc_list():
    """
        function to gather kubernetes PVC information
    """
    cmd = OPT.kube_cli + " get pvc {}".format(get_namespace_argument())
    collect_helper(cmd, file_name="pvc.list", resource_name="pvc-list")


def collect_pvc_details():
    """
        function to gather kubernetes PVC details
    """
    cmd = OPT.kube_cli + " get pvc -o yaml {}".format(get_namespace_argument())
    collect_helper(cmd, file_name="pvc.details", resource_name="pvc-details")


def collect_configmap_list():
    """
        function to gather configmap list
    """
    cmd = OPT.kube_cli + " get configmap {}".format(get_namespace_argument())
    collect_helper(cmd, file_name="configmap.list",
                   resource_name="configmap-list")


def collect_configmap_details():
    """
        function to gather configmap details
    """
    cmd = (OPT.kube_cli +
           " get configmap -o yaml {}".format(get_namespace_argument()))
    collect_helper(cmd, file_name="configmap.details",
                   resource_name="configmap-details")


def collect_events():
    """
        function to gather k8s events
    """
    cmd = OPT.kube_cli + " get events {}".format(get_namespace_argument())
    collect_helper(cmd=cmd, file_name="events", resource_name="k8s events")


def collect_api_resources():
    """
        function to gather details on different k8s resources
    """
    logger.info("Collecting API resources:")
    resources_out = OrderedDict()
    for resource in API_RESOURCES:
        if OPT.kube_cli == "kubectl" and resource == "Routes":
            continue
        output = run_kube_get(resource)
        if output:
            resources_out[resource] = run_kube_get(resource)
            logger.info("  + %s", resource)

    for entry, out in resources_out.items():
        with open(posixpath.join(OPT.output_dir, f"{entry}.yml"), "wb") as file_pointer:
            file_pointer.write(out)


def collect_pods_describe():
    """
        function to gather k8s describe on the namespace pods
    """
    cmd = OPT.kube_cli + " describe pods {}".format(get_namespace_argument())
    collect_helper(cmd=cmd, file_name="describe-pods", resource_name="pod describe")


def collect_pods_logs():
    """
        Collects all the pods logs from a given namespace
    """
    logger.info("Collecting pod logs:")
    logs_dir = posixpath.join(OPT.output_dir, "pod_logs")
    os.makedirs(logs_dir)

    pods = get_pods_v4() + get_op_pod()
    if not pods:
        logger.debug("No Pods found, trying PGO V5 methods...")
        pods = get_pods_v5() + get_op_pod()
        if not pods:
            logger.warning("Could not get pods list - skipping automatic pod logs collection")
            logger.error("########")
            logger.error("#### You will need to collect these pod logs manually ####")
            logger.error("########")
            logger.warning("»HINT: Was the correct namespace used?")
            logger.debug("This error sometimes happens when labels have been modified")
            return

    logger.info("Found and processing the following containers:")
    for pod in pods:
        containers = get_containers(pod)
        if not containers:
            logger.warning("Could not get pods list")
            logger.warning("»HINT: Were the labels modified?")
            logger.warning("»HINT: Was the correct namespace used?")
            logger.error("########")
            logger.error("#### You will need to collect these pod logs manually ####")
            logger.error("########")
            logger.debug("This error sometimes happens when labels have been modified")
            return
        for cont in containers:
            container = cont.rstrip()
            cmd = (OPT.kube_cli + " logs {} {} -c {}".
                   format(get_namespace_argument(), pod, container))
            with open("{}/{}_{}.log".format(logs_dir, pod,
                                            container), "wb") as file_pointer:
                handle = subprocess.Popen(cmd, shell=True,
                                          stdout=subprocess.PIPE,
                                          stderr=subprocess.STDOUT)
                while True:
                    line = handle.stdout.readline()
                    if line:
                        file_pointer.write(line)
                    else:
                        break
            logger.info("  + pod:%s, container:%s", pod, container)


def collect_pg_pod_details():
    """
        Collects PG pods details
    """
    logger.info("Collecting PG pod details:")
    logs_dir = posixpath.join(OPT.output_dir, "pg_pod_details")
    os.makedirs(logs_dir)

    pods = get_pg_pods_v4()
    if not pods:
        logger.debug("No Pods found, trying PGO V5 methods...")
        pods = get_pg_pods_v5()
        if not pods:
            logger.warning("Could not get pods list - skipping PG pod details collection")
            logger.error("########")
            logger.error("#### You will need to collect Postgres pod logs manually ####")
            logger.error("########")
            logger.warning("»HINT: Was the correct namespace used?")
            logger.debug("This error sometimes happens when labels have been modified")
            return

    logger.info("Found and processing the following containers:")
    for pod in pods:
        containers = get_containers(pod)
        for cont in containers:
            container = cont.rstrip()
            with open("{}/{}_{}.log".format(logs_dir, pod,
                                            container), "ab+") as file_pointer:
                for command in (CONTAINER_COMMANDS['all'] +
                                CONTAINER_COMMANDS[container]):
                    cmd = (OPT.kube_cli + " exec -it {} -c {} {} -- "
                           "/bin/bash -c '{}'"
                           .format(get_namespace_argument(),
                                   container, pod, command))
                    handle = subprocess.Popen(cmd, shell=True,
                                              stdout=file_pointer.fileno(),
                                              stderr=file_pointer.fileno())
                    try:
                        out=handle.communicate(timeout=60)
                    except subprocess.TimeoutExpired:
                        logger.warning("The output for " + cmd + " was not captured due to timeout")
                        handle.kill()
            logger.info("  + pod:%s, container:%s", pod, container)


def collect_pg_logs():
    """
        Collects PG database server logs
    """
    logger.info("Collecting last %s PG logs "
                "(may take a while)", OPT.pg_logs_count)
    logs_dir = posixpath.join(OPT.output_dir, "pg_logs")
    os.makedirs(logs_dir)
    pods = get_pg_pods_v4()
    if not pods:
        logger.debug("No Pods found, trying PGO V5 methods...")
        pods = get_pg_pods_v5()
        if not pods:
            logger.warning("Could not get pods list - skipping pods logs collection")
            logger.error("########")
            logger.error("#### You will need to collect these Postgres logs manually ####")
            logger.error("########")
            logger.warning("»HINT: Was the correct namespace used?")
            logger.debug("This error sometimes happens when labels have been modified")
            return

    logger.info("Found and processing the following containers:")
    for pod in pods:
        tgt_file = "{}/{}".format(logs_dir, pod)
        os.makedirs(tgt_file)
        # print("OPT.pg_logs_count:  ", OPT.pg_logs_count)
        cmd = (OPT.kube_cli +
               " exec -it {} -c database {} -- /bin/bash -c"
               " 'ls -1dt /pgdata/*/pglogs/* | head -{}'"
               .format(get_namespace_argument(), pod, OPT.pg_logs_count))
        # print(cmd)
        handle = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        while True:
            line = handle.stdout.readline()
            if line:
                cmd = (OPT.kube_cli +
                       " cp -c database {} {}:{} {}"
                       .format(get_namespace_argument(),
                               pod, line.rstrip().decode('UTF-8'),
                               tgt_file + line.rstrip().decode('UTF-8')))
                handle2 = subprocess.Popen(cmd, shell=True,
                                           stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT)
                handle2.wait()
            else:
                break
        logger.info("  + pod:%s", pod)


def sizeof_fmt(num, suffix="B"):
    """
        Formats the file size in a human-readable format
        Probably overkill to go to Zi range, but reusable
    """
    for unit in ["", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi"]:
        if abs(num) < 1024.0:
            return f"{num:3.1f}{unit}{suffix}"
        num /= 1024.0
    return f"{num:.1f}Yi{suffix}"


def archive_files():
    """
        Create an archive and compress it
    """
    archive_file_size = 0
    file_name = OPT.output_dir + ".tar.gz"

    with tarfile.open(file_name, "w|gz") as tar:
        tar.add(OPT.output_dir, arcname=OPT.dir_name)
    logger.info("")

    # Let user choose to delete the files manually

    if OPT.delete_dir:
        rtn, out = run_shell_command(f"rm -rf {OPT.output_dir}")
        if rtn:
            logger.warning('Failed to delete directory after archiving: %s',
                           out)
            logger.info("support dump files saved at %s", OPT.output_dir)
    try:
        archive_file_size = os.stat(file_name).st_size
        logger.info("┌──────────────────────────────────────────────────────────────────-")
        logger.info("│ Archive file saved to: %s ", file_name)
        if archive_file_size > MAX_ARCHIVE_EMAIL_SIZE:
            logger.info("│ Archive file (%d) may be too big to email.",
                        sizeof_fmt(archive_file_size))
            logger.info("│ Please request file share link by"
                        " emailing support@crunchydata.com")
        else:
            logger.info("│ Archive file size: %s ", sizeof_fmt(archive_file_size))
            logger.info("│ Email the support dump to support@crunchydata.com")
            logger.info("│ or attach as a email reply to your existing Support Ticket")
        logger.info("└──────────────────────────────────────────────────────────────────-")
    except (OSError, ValueError) as e:  # pylint: disable=invalid-name
        logger.warning("Archive file size: NA --- %s", e)


def get_pods_v4():
    """
        Returns list of pods names, all pods
    """
    cmd = (OPT.kube_cli + " get pod {} -lvendor=crunchydata "
           "-o=custom-columns=NAME:.metadata.name "
           "--no-headers".format(get_namespace_argument()))
    return_code, out = run_shell_command(cmd)
    if return_code == 0:
        return out.decode("utf-8").split("\n")[:-1]
    logger.warning("Failed to get pods: %s", out)
    return None


def get_pods_v5():
    """
        Returns list of pods names, all pods
    """
    cmd = (OPT.kube_cli + " get pod {} "
           "-lpostgres-operator.crunchydata.com/cluster "
           "-o=custom-columns=NAME:.metadata.name "
           "--no-headers".format(get_namespace_argument()))
    return_code, out = run_shell_command(cmd)
    if return_code == 0:
        return out.decode("utf-8").split("\n")[:-1]
    logger.warning("Failed to get pods: %s", out)
    return None


def get_op_pod():
    """
        Returns just the operator pod
    """
    cmd = (OPT.kube_cli + " get pod {} "
           "-lapp.kubernetes.io/name=postgres-operator "
           "-o=custom-columns=NAME:.metadata.name "
           "--no-headers".format(get_namespace_argument()))
    return_code, out = run_shell_command(cmd)
    if return_code == 0:
        return out.decode("utf-8").split("\n")[:-1]
    logger.warning("Failed to get pods: %s", out)
    return None


def get_pg_pods_v4():
    """
        Returns list of pods names, only DB pods
    """
    cmd = (OPT.kube_cli + " get pod {} "
           "-lpgo-pg-database=true,vendor=crunchydata "
           "-o=custom-columns=NAME:.metadata.name "
           "--no-headers".format(get_namespace_argument()))
    return_code, out = run_shell_command(cmd)
    if return_code == 0:
        return out.decode("utf-8").split("\n")[:-1]
    logger.warning("Failed to get pods: %s", out)
    return None


def get_pg_pods_v5():
    """
        Returns list of pods names, only DB pods
    """
    cmd = (OPT.kube_cli + " get pod {} "
           "-lpostgres-operator.crunchydata.com/cluster "
           "-o=custom-columns=NAME:.metadata.name "
           "--no-headers".format(get_namespace_argument()))
    return_code, out = run_shell_command(cmd)
    if return_code == 0:
        return out.decode("utf-8").split("\n")[:-1]
    logger.warning("Failed to get pods: %s", out)
    return None


def get_containers(pod_name):
    """
        Returns list of containers in a pod
    """
    cmd = (OPT.kube_cli + " get pods {} {} --no-headers "
           "-o=custom-columns=CONTAINERS:.spec.containers[*].name"
           .format(get_namespace_argument(), pod_name))
    return_code, out = run_shell_command(cmd)
    if return_code == 0:
        return out.decode("utf-8").split(",")
    logger.warning("Failed to get pods: %s", out)
    return None


def get_namespace_argument():
    """
        Returns namespace option for kube cli
    """
    if OPT.namespace:
        return "-n {}".format(OPT.namespace)
    return ""


def collect_helper(cmd, file_name, resource_name):
    """
        helper function to gather data
    """
    return_code, out = run_shell_command(cmd)
    if return_code:
        logger.warning("Error when running %s: %s", cmd, out.decode('utf-8').rstrip())
        return
    path = posixpath.join(OPT.output_dir, file_name)
    with open(path, "wb") as file_pointer:
        file_pointer.write(out)
    logger.info("Collected %s", resource_name)


def run_shell_command(cmd, log_error=True):
    """
        Returns a tuple of the shell exit code, output
    """
    try:
        output = subprocess.check_output(
            cmd,
            shell=True,
            stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as ex:
        if log_error:
            logger.debug("Failed in shell command: %s, output: %s",
                    cmd, ex.output.decode('utf-8').rstrip())
            logger.debug("This is probably fine; an item which doesn't exist in v4/v5")
        return ex.returncode, ex.output

    return 0, output


def run_kube_get(resource_type):
    """
        Returns a tuple of the shell exit code, and kube cli get output
    """
    cmd = OPT.kube_cli + " get {} {} -o yaml".format(resource_type,
                                                     get_namespace_argument())
    return_code, out = run_shell_command(cmd)
    if return_code == 0:
        return out
    logger.debug("Failed to get %s resource: %s. Resource may not exist",
            resource_type,
            out.decode('utf-8').rstrip())
    logger.debug("This is probably fine; an item which doesn't exist in v4/v5")
    return None


def get_kube_cli():
    """
        Determine which kube CLI to use
    """
    cmd = "which oc"
    return_code, _ = run_shell_command(cmd, False)
    if return_code == 0:
        return "oc"

    cmd = "which kubectl"
    return_code, _ = run_shell_command(cmd, False)
    if return_code == 0:
        return "kubectl"
    logger.error("kubernetes CLI not found")
    sys.exit()


def check_kube_access():
    """
        Check if the user has access to kube cluster
    """
    if OPT.kube_cli == "oc":
        cmd = "oc whoami"
    else:
        cmd = "kubectl cluster-info"

    return_code, _ = run_shell_command(cmd)
    return return_code


if __name__ == "__main__":
    allowed_cli = ("kubectl", "oc")

    parser = argparse.ArgumentParser(description='Crunchy support dump'
                                     'collector', add_help=True)

    namedArgs = parser.add_argument_group('Named arguments')
    namedArgs.add_argument('-n', '--namespace', required=True,
                           action="store", type=str,
                           help='kubernetes namespace to dump')
    namedArgs.add_argument('-o', '--dest_dir', required=True,
                           action="store", type=str,
                           help='path to save dump tarball')
    namedArgs.add_argument('-l', '--pg_logs_count', required=False,
                           action="store", type=int, default=2,
                           help='number of pg_log files to save')
    namedArgs.add_argument('-d', '--delete_dir', required=False,
                           action="store_true",
                           help='delete the temporary working directory')
    namedArgs.add_argument('-c', '--client_program', required=False,
                           type=str, action="store",
                           help='client program.  valid options:  '
                           + str(allowed_cli))

    results = parser.parse_args()
    OPT.namespace = results.namespace
    OPT.dest_dir = results.dest_dir
    OPT.pg_logs_count = results.pg_logs_count
    OPT.delete_dir = results.delete_dir

    # Initialize the target for logging and file collection
    if OPT.dest_dir:
        OPT.output_dir = posixpath.join(OPT.dest_dir, OPT.dir_name)
    else:
        OPT.output_dir = (posixpath.join(posixpath.abspath(__file__),
                                         OPT.dir_name))

    try:
        os.makedirs(OPT.output_dir)
    except OSError as error:
        print(error)

    # Log everything to the file, only info+ to stdout
    logging.basicConfig(
            level=logging.DEBUG,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(f"{OPT.output_dir}/dumptool.log"),
                ]
            )
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    logging.getLogger('').addHandler(console)

    logger.info("┌────────────────────────────────────────────────────────────────────────────-")
    logger.info("│ Crunchy Support Dump Collector")
    logger.info("│ NOTE: This tool gathers metadata and pod logs only.")
    logger.info("│ (No data or k8s secrets)")
    logger.info("└────────────────────────────────────────────────────────────────────────────-")

    if results.client_program is not None:
        if results.client_program in allowed_cli:
            OPT.kube_cli = results.client_program
        else:
            logger.error("Invalid optional client program "
                         "argument:  %s.  Valid choices:  %s.",
                         results.client_program,
                         str(allowed_cli))
            sys.exit()
    else:
        OPT.kube_cli = get_kube_cli()

    if check_kube_access() != 0:
        logger.error("Not connected to kubernetes cluster")
        sys.exit()

    run()
EOF
}

#------------------------------------------------------------------------------------------------------

#------------------------------------------- Set variables --------------------------------------------
LOG_PATH="/tmp"
CURRENT_PATH=`pwd`
TIMESTAMP=`date +%Y%m%dT%H%M%S%Z`
TEMP_NAME="postmortem-$TIMESTAMP"
TEMP_PATH="${LOG_PATH}/${TEMP_NAME}"

if [[ -z "$NAMESPACE_LIST" ]]; then
    NAMESPACE_LIST="kube-system"
fi
if [[ -z "$AUTO_DETECT" ]]; then
    AUTO_DETECT=1
fi

ARCHIVE_FILE=""

ERROR_REPORT_SLEEP_TIMEOUT=30

MIN_DOCKER_VERSION="17.03"
MIN_KUBELET_VERSION="1.17"

COLOR_YELLOW=`tput setaf 3`
COLOR_WHITE=`tput setaf 7`
COLOR_RESET=`tput sgr0`
#------------------------------------------------------------------------------------------------------

#------------------------------------------- Clean up area --------------------------------------------
function cleanup {
  echo "Cleaning up.  Removing directory [$TEMP_PATH]."
  rm -fr $TEMP_PATH
}

trap cleanup EXIT
#------------------------------------------------------------------------------------------------------
#=================================================================================================================

echo -e "Generating postmortem, please wait..."

mkdir -p $TEMP_PATH

#determine if metrics is installed
$KUBECTL get pods --all-namespaces 2>/dev/null | egrep -q "metrics-server|openshift-monitoring"
OUTPUT_METRICS=$?

#Namespaces
for NAMESPACE_OPTIONS in "rook-ceph" "rook-ceph-system" "ibm-common-services" "openshift-marketplace" "openshift-operators" "openshift-operator-lifecycle-manager" "cert-manager" "certmanager" ;
    do
        $KUBECTL get ns 2>/dev/null | grep -q "$NAMESPACE_OPTIONS"
        if [[ $? -eq 0 && $SPECIFIC_NAMESPACES -ne 1 ]]; then
            NAMESPACE_LIST+=" $NAMESPACE_OPTIONS"
        fi
    done

#================================================= pull ova data =================================================
if [[ $IS_OVA -eq 1 ]]; then

    #Creating Directories
    OVA_DATA="${TEMP_PATH}/ova"
    mkdir -p $OVA_DATA
    OVA_FILESYSTEM="${OVA_DATA}/filesystem"
    mkdir -p $OVA_FILESYSTEM
    CONTAINERRUNTIMEFOLDER="${OVA_DATA}/container-runtime"
    CONTAINERD="${CONTAINERRUNTIMEFOLDER}/containerd"
    DOCKERFOLDER="${CONTAINERRUNTIMEFOLDER}/docker"
    DOCKERLOGSFOLDER="${DOCKERFOLDER}/logs"
    mkdir -p $DOCKERLOGSFOLDER
    mkdir -p $CONTAINERD
    OVA_LIBFOLDER="${OVA_FILESYSTEM}/var/lib"
    OVA_USRLOCALLIBFOLDER="${OVA_FILESYSTEM}/usr/local/lib"
    mkdir -p $OVA_LIBFOLDER
    mkdir -p $OVA_USRLOCALLIBFOLDER


    #grab version
    sudo apic version 1>"${OVA_DATA}/version.out" 2>/dev/null

    #grab status
    sudo apic status 1>"${OVA_DATA}/status.out" 2>/dev/null

    #grab health-check
    sudo apic health-check -v >"${OVA_DATA}/health-check.out" 2>&1

    #grab subsystem history
    sudo apic subsystem 1>"${OVA_DATA}/subsystem-history.out" 2>/dev/null

    #grab CR yaml from /var/lib/apiconnect/subsystem/manifests
    sudo cp /var/lib/apiconnect/subsystem/manifests/"$(ls -1 /var/lib/apiconnect/subsystem/manifests | tail -n 1)" "${OVA_DATA}/subsystem-cr.yaml" 2>/dev/null

    #grab bash history
    if [[ $NO_HISTORY -ne 1 ]]; then
        HISTFILE=~/.bash_history
        set -o history
        HISTTIMEFORMAT="%F %T " history >> "${OVA_DATA}/root-timestamped-bash_history.out"
        cp "/home/apicadm/.bash_history" "${OVA_DATA}/apicadm-bash_history.out" &>/dev/null
        cp "/root/.bash_history" "${OVA_DATA}/root-bash_history.out" &>/dev/null
    fi

    #pull disk data
    echo -e "> blkid /dev/sr0" >"${OVA_DATA}/disk_data.out" 2>/dev/null
    blkid /dev/sr0 1>>"${OVA_DATA}/disk_data.out" 2>/dev/null
    echo -e "\n> lsblk -fp" 1>>"${OVA_DATA}/disk_data.out" 2>/dev/null
    lsblk -fp 1>>"${OVA_DATA}/disk_data.out" 2>/dev/null
    echo -e "\n>df -kh | egrep -v 'kubelet|docker'" 1>>"${OVA_DATA}/disk_data.out" 2>/dev/null
    df -kh | egrep -v 'kubelet|docker' 1>>"${OVA_DATA}/disk_data.out" 2>/dev/null

    #pull appliance logs
    cd $OVA_DATA
    sudo apic logs &>/dev/null

    #pull files from var/log
    cp -r --parents /var/log/containers "${OVA_FILESYSTEM}"
    find "/var/log" -name "cloud-init.log" -exec cp '{}' "${OVA_FILESYSTEM}"/var/log \;
    find "/var/log" -name "cloud-init-output.log" -exec cp '{}' "${OVA_FILESYSTEM}"/var/log \;
    find "/var/log" -name "dmesg" -exec cp '{}' "${OVA_FILESYSTEM}"/var/log \;
    find "/var/log" -name "*syslog*" -exec cp '{}' "${OVA_FILESYSTEM}"/var/log \;
    find "/var/log" -name "nmon" -exec cp -r '{}' "${OVA_FILESYSTEM}"/var/log \;

    #Getting contents of etc/ssh custom configuration files
    cp -r --parents /etc/ssh/{ssh_config.d,sshd_config.d}/ "${OVA_FILESYSTEM}"

    #Getting contents of etc/netplan
    cp -r --parents /etc/netplan/ "${OVA_FILESYSTEM}"

    #Getting appliance-control-plane-current
    find "/var/lib/apiconnect" -name "appliance-control-plane-current" -exec cp '{}' "${OVA_DATA}/" \;

    #Getting content of /etc/kubernetes directory recursively
    cp -r --parents /etc/kubernetes/ "${OVA_FILESYSTEM}"

    #Get volumes
    du -h -d 1 /data/secure/volumes | sort -h &> "${OVA_DATA}/volumes-disk-usage.out"

    #Get time/date information
    timedatectl &> "${OVA_DATA}/timedatectl.out"

    #Getting authorized keys
    cat /home/apicadm/.ssh/authorized_keys &> "${OVA_DATA}/authorized-keys.out"

    #Getting content of etc/apt
    cp -r --parents /etc/apt/ "${OVA_FILESYSTEM}"

    which crictl &> /dev/null
    if [[ $? -eq 0 ]]; then
        #Setting the crictl runtime endpoint
        crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock

        #Getting crictl version
        crictl version &> "${CONTAINERD}/crictl-version.out"

        #Getting Crictl Logs
        crictl ps -a &>"${CONTAINERD}/containatinerd-containers.out"
    fi

    #Getting Docker Logs
    OUTPUT=`docker ps -a 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${DOCKERFOLDER}/docker-containers.out"
        while read line; do
            CONTAINERID=`echo "$line" | cut -d' ' -f1`
            docker logs $CONTAINERID &> "${DOCKERLOGSFOLDER}/${CONTAINERID}.out"
            [ $? -eq 0 ] || rm -f "${DOCKERLOGSFOLDER}/${CONTAINERID}.out"
        done <<< "$OUTPUT"
    fi

    #Get Docker and Crictl Version
    docker version &> "${DOCKERFOLDER}/docker-version.out"

    #Getting subsystem meta file content
    cat /var/lib/apiconnect-subsystem/meta.yml 1>"${OVA_LIBFOLDER}/subsystem-meta.out" 2>/dev/null

    #Getting side-registry recursive file listing
    find /var/lib/apiconnect/side-registry/ 1>"${OVA_LIBFOLDER}/side-registry.out" 2>/dev/null

    #Getting appliance-control-plane recursive file listing
    find /usr/local/lib/appliance-control-plane/ 1>"${OVA_USRLOCALLIBFOLDER}/appliance-control-plane.out" 2>/dev/null

    #Getting appliance-side-registry recursive file listing
    find /usr/local/lib/appliance-side-registry/ 1>"${OVA_USRLOCALLIBFOLDER}/appliance-side-registry.out" 2>/dev/null

fi
#=================================================================================================================

#============================================== autodetect namespaces ============================================

SUBSYS_MANAGER="ISNOTSET"
SUBSYS_ANALYTICS="ISNOTSET"
SUBSYS_PORTAL="ISNOTSET"
SUBSYS_GATEWAY_V5="ISNOTSET"
SUBSYS_GATEWAY_V6="ISNOTSET"
SUBSYS_EVENT="ISNOTSET"

SUBSYS_MANAGER_COUNT=0
SUBSYS_ANALYTICS_COUNT=0
SUBSYS_PORTAL_COUNT=0
SUBSYS_GATEWAY_V5_COUNT=0
SUBSYS_GATEWAY_V6_COUNT=0
SUBSYS_EVENT_COUNT=0

CLUSTER_LIST=(ManagementCluster AnalyticsCluster PortalCluster GatewayCluster EventEndpointManager EventGatewayCluster)
EVENT_PREFIX="eventendpo"
ns_matches=""

getClusters () {
    CLUSTER_LIST=(ManagementCluster AnalyticsCluster PortalCluster GatewayCluster EventEndpointManager EventGatewayCluster)
    ns=`echo "$1" | awk '{print $1}'`
    echo "Checking namespace $ns for cluster resources"

    for cluster in ${CLUSTER_LIST[@]}; do
        OUTPUT=`$KUBECTL get -n $ns $cluster 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            OUTPUT=`echo "${OUTPUT}" | grep -v NAME`
            while read line; do
                name=`echo ${line} | awk '{print $1}'`
                if [[ ${#name} -gt 10 ]]; then
                    event_name=${name:0:10}
                else
                    event_name=$name
                fi

                case $cluster in
                    "ManagementCluster")
                        if [[ "${event_name}" != "${EVENT_PREFIX}"* ]]; then
                            if [[ ${SUBSYS_MANAGER} == "ISNOTSET" ]]; then
                                SUBSYS_MANAGER=$name
                            else
                                SUBSYS_MANAGER+=" ${name}"
                            fi
                            ((SUBSYS_MANAGER_COUNT=SUBSYS_MANAGER_COUNT+1))
                            echo "Found ManagementCluster $event_name"
                        fi
                    ;;
                    "AnalyticsCluster")
                        if [[ ${SUBSYS_ANALYTICS} == "ISNOTSET" ]]; then
                            SUBSYS_ANALYTICS=$name
                        else
                            SUBSYS_ANALYTICS+=" ${name}"
                        fi
                        ((SUBSYS_ANALYTICS_COUNT=SUBSYS_ANALYTICS_COUNT+1))
                        echo "Found AnalyticsCluster $event_name"
                    ;;
                    "PortalCluster")
                        if [[ "${event_name}" != "${EVENT_PREFIX}"* ]]; then
                            if [[ ${SUBSYS_PORTAL} == "ISNOTSET" ]]; then
                                SUBSYS_PORTAL=$name
                            else
                                SUBSYS_PORTAL+=" ${name}"
                            fi
                            ((SUBSYS_PORTAL_COUNT=SUBSYS_PORTAL_COUNT+1))
                            echo "Found PortalCluster $event_name"
                        fi
                    ;;
                    "GatewayCluster")
                        if [[ "$name" == *"v5"* ]]; then
                            if [[ ${SUBSYS_GATEWAY_V5} == "ISNOTSET" ]]; then
                                SUBSYS_GATEWAY_V5=$name
                            else
                                SUBSYS_GATEWAY_V5+=" ${name}"
                            fi
                            ((SUBSYS_GATEWAY_V5_COUNT=SUBSYS_GATEWAY_V5_COUNT+1))
                            echo "Found V5 GatewayCluster $event_name"
                        else
                            if [[ ${SUBSYS_GATEWAY_V6} == "ISNOTSET" ]]; then
                                SUBSYS_GATEWAY_V6=$name
                            else
                                SUBSYS_GATEWAY_V6+=" ${name}"
                            fi
                            ((SUBSYS_GATEWAY_V6_COUNT=SUBSYS_GATEWAY_V6_COUNT+1))
                            echo "Found V6 GatewayCluster $event_name"
                        fi
                    ;;
                    "EventEndpointManager" | "EventGatewayCluster")
                        if [[ ${SUBSYS_EVENT} == "ISNOTSET" ]]; then
                            SUBSYS_EVENT=$event_name
                        else
                            SUBSYS_EVENT+=" ${event_name}"
                        fi
                        ((SUBSYS_EVENT_COUNT=SUBSYS_EVENT_COUNT+1))
                        echo "Found EventEndpointManager $event_name"
                    ;;
                esac

                if [[ "${ns_matches}" != *"${ns}"* ]]; then
                    if [[ ${#ns_matches} -eq 0 ]]; then
                        ns_matches=$ns
                    else
                        ns_matches+=" ${ns}"
                    fi
                fi
            done <<< "$OUTPUT"
        fi
    done
}

if [[ $AUTO_DETECT -eq 1 ]]; then
    NS_LISTING=`$KUBECTL get ns 2>/dev/null | sed -e '1d' | egrep -v "kube-system|cert-manager|rook|certmanager"`
    while read line; do
        getClusters $line
    done <<< "$NS_LISTING"
else
    NS_LISTING=$(echo $NAMESPACE_LIST | tr ',' ' ')
    for ns in $NS_LISTING; do
        getClusters $ns
    done
fi

space_count=`echo "${ns_matches}" | tr -cd ' \t' | wc -c`
[ $SPECIFIC_NAMESPACES -eq 1 ] || echo -e "Auto-detected namespaces [${ns_matches}]."

if [[ $space_count -gt 0 && $NO_PROMPT -eq 0 ]]; then
    read -p "Proceed with data collection (y/n)? " yn
    case $yn in
        [Yy]* )
            echo -e "Proceeding..."
            ;;
        [Nn]* )
            echo -e "Exiting..."
            exit 1
            ;;
    esac
fi

[ $SPECIFIC_NAMESPACES -eq 1 ] || NAMESPACE_LIST+=" ${ns_matches}"

#=================================================================================================================

#============================================= pull kubernetes data ==============================================
#----------------------------------------- create directories -----------------------------------------
K8S_DATA="${TEMP_PATH}/kubernetes"

K8S_CLUSTER="${K8S_DATA}/cluster"
K8S_NAMESPACES="${K8S_DATA}/namespaces"
K8S_VERSION="${K8S_DATA}/versions"

K8S_CLUSTER_NODE_DATA="${K8S_CLUSTER}/nodes"
K8S_CLUSTER_NODE_DESCRIBE_DATA="${K8S_CLUSTER_NODE_DATA}/describe"

K8S_CLUSTER_LIST_DATA="${K8S_CLUSTER}/lists"
K8S_CLUSTER_ROLE_DATA="${K8S_CLUSTER}/clusterroles"
K8S_CLUSTER_ROLEBINDING_DATA="${K8S_CLUSTER}/clusterrolebindings"

K8S_CLUSTER_CRD_DATA="${K8S_CLUSTER}/crd"
K8S_CLUSTER_CRD_DESCRIBE_DATA="${K8S_CLUSTER_CRD_DATA}/describe"

K8S_CLUSTER_PV_DATA="${K8S_CLUSTER}/pv"
K8S_CLUSTER_PV_DESCRIBE_DATA="${K8S_CLUSTER_PV_DATA}/describe"

K8S_CLUSTER_STORAGECLASS_DATA="${K8S_CLUSTER}/storageclasses"
K8S_CLUSTER_STORAGECLASS_DESCRIBE_DATA="${K8S_CLUSTER_STORAGECLASS_DATA}/describe"

K8S_CLUSTER_PERFORMANCE="${K8S_CLUSTER}/performance"

K8S_CLUSTER_VALIDATINGWEBHOOK_CONFIGURATIONS="${K8S_CLUSTER}/validatingwebhookconfigurations"
K8S_CLUSTER_VALIDATINGWEBHOOK_YAML_OUTPUT="${K8S_CLUSTER_VALIDATINGWEBHOOK_CONFIGURATIONS}/yaml"

K8S_CLUSTER_MUTATINGWEBHOOK_CONFIGURATIONS="${K8S_CLUSTER}/mutatingwebhookconfigurations"
K8S_CLUSTER_MUTATINGWEBHOOK_YAML_OUTPUT="${K8S_CLUSTER_MUTATINGWEBHOOK_CONFIGURATIONS}/yaml"


mkdir -p $K8S_VERSION

mkdir -p $K8S_CLUSTER_LIST_DATA
mkdir -p $K8S_CLUSTER_ROLE_DATA
mkdir -p $K8S_CLUSTER_ROLEBINDING_DATA

mkdir -p $K8S_CLUSTER_NODE_DESCRIBE_DATA
mkdir -p $K8S_CLUSTER_CRD_DESCRIBE_DATA
mkdir -p $K8S_CLUSTER_PV_DESCRIBE_DATA
mkdir -p $K8S_CLUSTER_STORAGECLASS_DESCRIBE_DATA

mkdir -p $K8S_CLUSTER_PERFORMANCE

mkdir -p $K8S_CLUSTER_VALIDATINGWEBHOOK_YAML_OUTPUT

mkdir -p $K8S_CLUSTER_MUTATINGWEBHOOK_YAML_OUTPUT

#------------------------------------------------------------------------------------------------------

#grab kubernetes version
$KUBECTL version 1>"${K8S_VERSION}/$KUBECTL.version" 2>/dev/null

#grab postmortem version
print_postmortem_version 1>"${K8S_VERSION}/postmortem.version" 2>/dev/null
#----------------------------------- collect cluster specific data ------------------------------------
#node
OUTPUT=`$KUBECTL get nodes 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" &> "${K8S_CLUSTER_NODE_DATA}/nodes.out"
    while read line; do
        name=`echo "$line" | awk -F ' ' '{print $1}'`
        role=`echo "$line" | awk -F ' ' '{print $3}'`

        describe_stdout=`$KUBECTL describe node $name 2>/dev/null`
        if [[ $? -eq 0 && ${#describe_stdout} -gt 0 ]]; then
            if [[ -z "$role" ]]; then
                echo "$describe_stdout" > "${K8S_CLUSTER_NODE_DESCRIBE_DATA}/${name}.out"
            else
                echo "$describe_stdout" > "${K8S_CLUSTER_NODE_DESCRIBE_DATA}/${name}_${role}.out"
            fi

            if [[ -z "$ARCHIVE_FILE" && "$role" == *"master"* ]]; then
                host=`echo $name | cut -d'.' -f1`
                if [[ -z "$host" ]]; then
                    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${TIMESTAMP}"
                else
                    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${host}-${TIMESTAMP}"
                fi
            fi
        fi
    done <<< "$OUTPUT"

    if [[ $OUTPUT_METRICS -eq 0 ]]; then
        $KUBECTL top nodes &> "${K8S_CLUSTER_NODE_DATA}/top.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_NODE_DATA}/top.out"
    fi
else
    rm -fr $K8S_CLUSTER_NODE_DATA
fi

if [[ -z "$ARCHIVE_FILE" ]]; then
    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${TIMESTAMP}"
fi

#cluster roles
OUTPUT=`$KUBECTL get clusterroles 2>/dev/null | cut -d' ' -f1`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    while read line; do
        $KUBECTL describe clusterrole $line &> "${K8S_CLUSTER_ROLE_DATA}/${line}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_ROLE_DATA}/${line}.out"
    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_ROLE_DATA
fi

#cluster rolebindings
OUTPUT=`$KUBECTL get clusterrolebindings 2>/dev/null | cut -d' ' -f1`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    while read line; do
        $KUBECTL describe clusterrolebinding $line &> "${K8S_CLUSTER_ROLEBINDING_DATA}/${line}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_ROLEBINDING_DATA}/${line}.out"
    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_ROLEBINDING_DATA
fi

#crds
OUTPUT=`$KUBECTL get crds 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_CRD_DATA}/crd.out"
    while read line; do
        crd=`echo "$line" | cut -d' ' -f1`
        $KUBECTL describe crd $crd &>"${K8S_CLUSTER_CRD_DESCRIBE_DATA}/${crd}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_CRD_DESCRIBE_DATA}/${crd}.out"
    done <<< "$OUTPUT"
fi

#pv
OUTPUT=`$KUBECTL get pv 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_PV_DATA}/pv.out"
    while read line; do
        pv=`echo "$line" | cut -d' ' -f1`
        $KUBECTL describe pv $pv &>"${K8S_CLUSTER_PV_DESCRIBE_DATA}/${pv}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_PV_DESCRIBE_DATA}/${pv}.out"
    done <<< "$OUTPUT"
fi

#storageclasses
OUTPUT=`$KUBECTL get storageclasses 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_STORAGECLASS_DATA}/storageclasses.out"
    while read line; do
        sc=`echo "$line" | cut -d' ' -f1`
        $KUBECTL describe storageclasses $sc &>"${K8S_CLUSTER_STORAGECLASS_DESCRIBE_DATA}/${sc}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_STORAGECLASS_DESCRIBE_DATA}/${sc}.out"
    done <<< "$OUTPUT"
fi

#check etcd cluster performance
if [[ $PERFORMANCE_CHECK -eq 1 ]]; then
    if [[ $IS_OVA -eq 1 ]]; then
        apic stage etcd-check-perf -l debug &> ${K8S_CLUSTER_PERFORMANCE}/etcd-performance.out # ova has special `apic stage` command that will run the etcd performance check and a defrag after
    else
        ETCD_POD=`$KUBECTL get pod -n kube-system --selector component=etcd -o=jsonpath={.items[0].metadata.name} 2>/dev/null` # retrieve name of etcd pod to exec
        # parse out etcd certs from pod describe
        ETCD_CA_FILE=`$KUBECTL describe pod -n kube-system ${ETCD_POD} | grep "\--trusted-ca-file" | cut -f2 -d"=" 2>/dev/null`
        ETCD_CERT_FILE=`$KUBECTL describe pod -n kube-system ${ETCD_POD} | grep "\--cert-file" | cut -f2 -d"=" 2>/dev/null`
        ETCD_KEY_FILE=`$KUBECTL describe pod -n kube-system ${ETCD_POD} | grep "\--key-file" | cut -f2 -d"=" 2>/dev/null`

        OUTPUT=`$KUBECTL exec -n kube-system ${ETCD_POD} -- sh -c "export ETCDCTL_API=3; etcdctl member list --cacert=${ETCD_CA_FILE} --cert=${ETCD_CERT_FILE} --key=${ETCD_KEY_FILE} 2>/dev/null"`

        # parsing endpoints from etcd member list
        ENDPOINTS=''
        while read line; do
            endpoint=`echo "$line" | awk '{print $5}'` # output formatting will change in etcd v3.4 so will need to update this
            if [[ ${#ENDPOINTS} -eq 0 ]]; then
                ENDPOINTS=$endpoint
            else
                ENDPOINTS="${ENDPOINTS},${endpoint}"
            fi
        done <<< "$OUTPUT"
        ENDPOINTS=${ENDPOINTS%,} # strip trailing comma

        # run etcd performance check
        OUTPUT=`$KUBECTL exec -n kube-system ${ETCD_POD} -- sh -c "export ETCDCTL_API=3; etcdctl check perf --endpoints="${ENDPOINTS}" --cacert=${ETCD_CA_FILE} --cert=${ETCD_CERT_FILE} --key=${ETCD_KEY_FILE}"`
        echo "${OUTPUT}" > ${K8S_CLUSTER_PERFORMANCE}/etcd-performance.out

        # run recommeneded `etcdctl defrag` to free up storage space
        OUTPUT=`$KUBECTL exec -n kube-system ${ETCD_POD} -- sh -c "export ETCDCTL_API=3; etcdctl defrag --endpoints="${ENDPOINTS}" --cacert=${ETCD_CA_FILE} --cert=${ETCD_CERT_FILE} --key=${ETCD_KEY_FILE}"`
        echo "${OUTPUT}" > ${K8S_CLUSTER_PERFORMANCE}/etcd-defrag.out
    fi
fi

#grab validataingwebhookconfiguation data
OUTPUT=`$KUBECTL get validatingwebhookconfiguration 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_VALIDATINGWEBHOOK_CONFIGURATIONS}/validatingwebhookconfigurations.out"
    while read line; do
        vwc=`echo "$line" | cut -d' ' -f1`
        $KUBECTL get validatingwebhookconfiguration $vwc -o yaml &> "${K8S_CLUSTER_VALIDATINGWEBHOOK_YAML_OUTPUT}/${vwc}.yaml"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_VALIDATINGWEBHOOK_YAML_OUTPUT}/${vwc}.yaml"

    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_VALIDATINGWEBHOOK_CONFIGURATIONS
fi

#grab mutatingwebhookconfiguration data
OUTPUT=`$KUBECTL get mutatingwebhookconfiguration 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_MUTATINGWEBHOOK_CONFIGURATIONS}/mutatingwebhookconfigurations.out"
    while read line; do
        mwc=`echo "$line" | cut -d' ' -f1`
        $KUBECTL get mutatingwebhookconfiguration $mwc -o yaml &> "${K8S_CLUSTER_MUTATINGWEBHOOK_YAML_OUTPUT}/${mwc}.yaml"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_MUTATINGWEBHOOK_YAML_OUTPUT}/${mwc}.yaml"

    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_MUTATINGWEBHOOK_CONFIGURATIONS
fi

#Describe SCC
OUTPUT=`$KUBECTL describe scc 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_LIST_DATA}/scc.out"
fi

#Get ImageContentSourcePolicy
OUTPUT=`$KUBECTL get imagecontentsourcepolicy -oyaml 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_LIST_DATA}/icsp.yaml"
fi

#Get api-resources
$KUBECTL api-resources &> "${K8S_CLUSTER_LIST_DATA}/api-resources.out"
#------------------------------------------------------------------------------------------------------

#---------------------------------- collect namespace specific data -----------------------------------
for NAMESPACE in $NAMESPACE_LIST; do
    echo "---- Collecting data in namespace: $NAMESPACE ----"

    K8S_NAMESPACES_SPECIFIC="${K8S_NAMESPACES}/${NAMESPACE}"

    K8S_NAMESPACES_LIST_DATA="${K8S_NAMESPACES_SPECIFIC}/lists"

    K8S_NAMESPACES_CLUSTER_DATA="${K8S_NAMESPACES_SPECIFIC}/clusters"
    K8S_NAMESPACES_CLUSTER_YAML_OUTPUT="${K8S_NAMESPACES_CLUSTER_DATA}/yaml"
    K8S_NAMESPACES_CLUSTER_DESCRIBE_DATA="${K8S_NAMESPACES_CLUSTER_DATA}/describe"

    K8S_NAMESPACES_CONFIGMAP_DATA="${K8S_NAMESPACES_SPECIFIC}/configmaps"
    K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT="${K8S_NAMESPACES_CONFIGMAP_DATA}/yaml"
    K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA="${K8S_NAMESPACES_CONFIGMAP_DATA}/describe"

    K8S_NAMESPACES_CRONJOB_DATA="${K8S_NAMESPACES_SPECIFIC}/cronjobs"
    K8S_NAMESPACES_CRONJOB_DESCRIBE_DATA="${K8S_NAMESPACES_CRONJOB_DATA}/describe"

    K8S_NAMESPACES_CRUNCHY_DATA="${K8S_NAMESPACES_SPECIFIC}/crunchy"

    K8S_NAMESPACES_EDB="${K8S_NAMESPACES_SPECIFIC}/edb"

    K8S_NAMESPACES_DAEMONSET_DATA="${K8S_NAMESPACES_SPECIFIC}/daemonsets"
    K8S_NAMESPACES_DAEMONSET_YAML_OUTPUT="${K8S_NAMESPACES_DAEMONSET_DATA}/yaml"
    K8S_NAMESPACES_DAEMONSET_DESCRIBE_DATA="${K8S_NAMESPACES_DAEMONSET_DATA}/describe"

    K8S_NAMESPACES_DEPLOYMENT_DATA="${K8S_NAMESPACES_SPECIFIC}/deployments"
    K8S_NAMESPACES_DEPLOYMENT_YAML_OUTPUT="${K8S_NAMESPACES_DEPLOYMENT_DATA}/yaml"
    K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA="${K8S_NAMESPACES_DEPLOYMENT_DATA}/describe"

    K8S_NAMESPACES_ENDPOINT_DATA="${K8S_NAMESPACES_SPECIFIC}/endpoints"
    K8S_NAMESPACES_ENDPOINT_DESCRIBE_DATA="${K8S_NAMESPACES_ENDPOINT_DATA}/describe"
    K8S_NAMESPACES_ENDPOINT_YAML_OUTPUT="${K8S_NAMESPACES_ENDPOINT_DATA}/yaml"

    K8S_NAMESPACES_JOB_DATA="${K8S_NAMESPACES_SPECIFIC}/jobs"
    K8S_NAMESPACES_JOB_DESCRIBE_DATA="${K8S_NAMESPACES_JOB_DATA}/describe"
    K8S_NAMESPACES_JOB_YAML_OUTPUT="${K8S_NAMESPACES_JOB_DATA}/yaml"

    K8S_NAMESPACES_POD_DATA="${K8S_NAMESPACES_SPECIFIC}/pods"
    K8S_NAMESPACES_POD_DESCRIBE_DATA="${K8S_NAMESPACES_POD_DATA}/describe"
    K8S_NAMESPACES_POD_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DATA}/diagnostic"
    K8S_NAMESPACES_POD_LOG_DATA="${K8S_NAMESPACES_POD_DATA}/logs"

    K8S_NAMESPACES_PVC_DATA="${K8S_NAMESPACES_SPECIFIC}/pvc"
    K8S_NAMESPACES_PVC_DESCRIBE_DATA="${K8S_NAMESPACES_PVC_DATA}/describe"

    K8S_NAMESPACES_PGTASKS_DATA="${K8S_NAMESPACES_SPECIFIC}/pgtasks"
    K8S_NAMESPACES_PGTASKS_DESCRIBE_DATA="${K8S_NAMESPACES_PGTASKS_DATA}/describe"

    K8S_NAMESPACES_REPLICASET_DATA="${K8S_NAMESPACES_SPECIFIC}/replicasets"
    K8S_NAMESPACES_REPLICASET_YAML_OUTPUT="${K8S_NAMESPACES_REPLICASET_DATA}/yaml"
    K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA="${K8S_NAMESPACES_REPLICASET_DATA}/describe"

    K8S_NAMESPACES_ROLE_DATA="${K8S_NAMESPACES_SPECIFIC}/roles"
    K8S_NAMESPACES_ROLE_DESCRIBE_DATA="${K8S_NAMESPACES_ROLE_DATA}/describe"

    K8S_NAMESPACES_ROLEBINDING_DATA="${K8S_NAMESPACES_SPECIFIC}/rolebindings"
    K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA="${K8S_NAMESPACES_ROLEBINDING_DATA}/describe"

    K8S_NAMESPACES_SA_DATA="${K8S_NAMESPACES_SPECIFIC}/serviceaccounts"
    K8S_NAMESPACES_SA_DESCRIBE_DATA="${K8S_NAMESPACES_SA_DATA}/describe"

    K8S_NAMESPACES_SECRET_DATA="${K8S_NAMESPACES_SPECIFIC}/secrets"
    K8S_NAMESPACES_SECRET_DESCRIBE_DATA="${K8S_NAMESPACES_SECRET_DATA}/describe"
    K8S_NAMESPACES_SECRET_YAML_OUTPUT="${K8S_NAMESPACES_SECRET_DATA}/yaml"

    K8S_NAMESPACES_SERVICE_DATA="${K8S_NAMESPACES_SPECIFIC}/services"
    K8S_NAMESPACES_SERVICE_DESCRIBE_DATA="${K8S_NAMESPACES_SERVICE_DATA}/describe"
    K8S_NAMESPACES_SERVICE_YAML_OUTPUT="${K8S_NAMESPACES_SERVICE_DATA}/yaml"

    K8S_NAMESPACES_STS_DATA="${K8S_NAMESPACES_SPECIFIC}/statefulset"
    K8S_NAMESPACES_STS_DESCRIBE_DATA="${K8S_NAMESPACES_STS_DATA}/describe"

    K8S_NAMESPACES_CERTS="${K8S_NAMESPACES_SPECIFIC}/certs"
    K8S_NAMESPACES_CERTS_YAML_OUTPUT="${K8S_NAMESPACES_CERTS}/yaml"

    K8S_NAMESPACES_ISSUERS="${K8S_NAMESPACES_SPECIFIC}/issuers"
    K8S_NAMESPACES_ISSUERS_YAML_OUTPUT="${K8S_NAMESPACES_ISSUERS}/yaml"


    mkdir -p $K8S_NAMESPACES_LIST_DATA

    mkdir -p $K8S_NAMESPACES_CLUSTER_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_CLUSTER_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_CRONJOB_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_CRUNCHY_DATA

    mkdir -p $K8S_NAMESPACES_EDB

    mkdir -p $K8S_NAMESPACES_DAEMONSET_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_DAEMONSET_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_DEPLOYMENT_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_ENDPOINT_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_ENDPOINT_YAML_OUTPUT

    mkdir -p $K8S_NAMESPACES_JOB_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_JOB_YAML_OUTPUT

    mkdir -p $K8S_NAMESPACES_POD_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_POD_LOG_DATA

    mkdir -p $K8S_NAMESPACES_PVC_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_PGTASKS_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_REPLICASET_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_ROLE_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_SA_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_SECRET_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_SECRET_YAML_OUTPUT

    mkdir -p $K8S_NAMESPACES_SERVICE_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_SERVICE_YAML_OUTPUT

    mkdir -p $K8S_NAMESPACES_STS_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_CERTS_YAML_OUTPUT

    mkdir -p $K8S_NAMESPACES_ISSUERS_YAML_OUTPUT



    #grab cluster configuration, equivalent to "apiconnect-up.yml" which now resides in cluster
    CLUSTER_LIST=(apic AnalyticsBackups AnalyticsClusters AnalyticsRestores APIConnectClusters DataPowerServices DataPowerMonitors EventEndpointManager EventGatewayClusters GatewayClusters ManagementBackups ManagementClusters ManagementDBUpgrades ManagementRestores NatsClusters NatsServiceRoles NatsStreamingClusters PGClusters PGPolicies PGReplicas PGTasks PortalBackups PortalClusters PortalRestores PortalSecretRotations backups clusters poolers scheduledbackups)
    for cluster in ${CLUSTER_LIST[@]}; do
        OUTPUT=`$KUBECTL get -n $NAMESPACE $cluster 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            echo "${OUTPUT}" > "${K8S_NAMESPACES_CLUSTER_DATA}/${cluster}.out"

            $KUBECTL describe $cluster -n $NAMESPACE &>"${K8S_NAMESPACES_CLUSTER_DESCRIBE_DATA}/${cluster}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CLUSTER_DESCRIBE_DATA}/${cluster}.out"

            $KUBECTL get $cluster -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_CLUSTER_YAML_OUTPUT}/${cluster}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CLUSTER_YAML_OUTPUT}/${cluster}.yaml"
        fi
    done

    #grab lists
    OUTPUT=`$KUBECTL get events -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/events.out"
    OUTPUT=`$KUBECTL get hpa -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/hpa.out"

    #grab ingress/routes then check each
    if [[ $IS_OCP ]]; then
        OUTPUT=`$KUBECTL get routes -n $NAMESPACE 2>/dev/null`
        ir_outfile="routes.out"
        ir_checks_outfile="routes-checks.out"
    else
        OUTPUT=`$KUBECTL get ingress -n $NAMESPACE 2>/dev/null`
        ir_outfile="ingress.out"
        ir_checks_outfile="ingress-checks.out"
    fi

    IR_OUTFILE="${K8S_NAMESPACES_LIST_DATA}/${ir_outfile}"
    IR_CHECKS_OUTFILE="${K8S_NAMESPACES_LIST_DATA}/${ir_checks_outfile}"

    if [[ ${#OUTPUT} -gt 0 && ! -f $IR_OUTFILE && ! -f $IR_CHECKS_OUTFILE ]]; then
        echo "$OUTPUT" > $IR_OUTFILE

        #check if portal pods are available to use nslookup
        OUTPUT1=`$KUBECTL get pods -n $NAMESPACE 2>/dev/null | egrep -v "up|downloads" | egrep "portal.*www|-apim-|-client-|-ui-" | head -n1`
        if [[ ${#OUTPUT1} -gt 0 ]]; then
            nslookup_pod=`echo "${OUTPUT1}" | awk '{print $1}'`
        fi

        #determine host column
        title_column=`echo "${OUTPUT}" | head -n1`
        column_count=`echo "${title_column}" | awk '{print NF}'`
        pos=1
        while [ $pos -lt $column_count ]; do
            token=`echo "${title_column}" | awk -v p=$pos '{print $p}'`
            if [[ "${token}" == *"HOST"* ]]; then
                break
            fi
            pos=$(( $pos + 1 ))
        done

        #check hosts
        if [[ ${#nslookup_pod} -gt 0 && $pos -lt $column_count ]]; then
            ingress_list=`echo "${OUTPUT}" | grep -v NAME | awk -v p=$pos '{print $p}' | uniq`
            at_start=1
            while read ingress; do
                nslookup_output=`$KUBECTL exec -n $NAMESPACE $nslookup_pod -- nslookup $ingress 2>&1`
                if [[ $at_start -eq 1 ]]; then
                    echo -e "${nslookup_output}" > $IR_CHECKS_OUTFILE
                else
                    echo -e "\n\n===============\n\n${nslookup_output}" >> $IR_CHECKS_OUTFILE
                fi
                at_start=0
            done <<< "$ingress_list"
        fi
    fi

    #grab configmap data
    OUTPUT=`$KUBECTL get configmaps -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_CONFIGMAP_DATA}/configmaps.out"
        while read line; do
            cm=`echo "$line" | cut -d' ' -f1`
            $KUBECTL get configmap $cm -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT}/${cm}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUTA}/${cm}.yaml"

            $KUBECTL describe configmap $cm -n $NAMESPACE &> "${K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA}/${cm}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA}/${cm}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_CONFIGMAP_DATA
    fi

    #grab certs
    OUTPUT=`$KUBECTL get certs -n $NAMESPACE -o wide 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_CERTS}/certs.out"
        while read line; do
            crt=`echo "$line" | cut -d' ' -f1`
            $KUBECTL get certs $crt -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_CERTS_YAML_OUTPUT}/${crt}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CERTS_YAML_OUTPUT}/${crt}.yaml"

        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_CERTS
    fi

    #grab issuers
    OUTPUT=`$KUBECTL get issuers -n $NAMESPACE -o wide 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ISSUERS}/issuers.out"
        while read line; do
            is=`echo "$line" | cut -d' ' -f1`
            $KUBECTL get issuers $is -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_ISSUERS_YAML_OUTPUT}/${is}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ISSUERS_YAML_OUTPUT}/${is}.yaml"

        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ISSUERS
    fi

    #grab cronjob data
    OUTPUT=`$KUBECTL get cronjobs -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_CRONJOB_DATA}/cronjobs.out"
        while read line; do
            cronjob=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe cronjob $cronjob -n $NAMESPACE &> "${K8S_NAMESPACES_CRONJOB_DESCRIBE_DATA}/${cronjob}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CRONJOB_DESCRIBE_DATA}/${cronjob}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_CRONJOB_DATA
    fi

    #grab crunchy mustgather
    if [[ $COLLECT_CRUNCHY -eq 1 && "$NAMESPACE" != "kube-system" ]]; then
        collectCrunchy
    fi

    #grab edb mustgather
    if [[ $COLLECT_EDB -eq 1 && "$NAMESPACE" != "kube-system" ]]; then
        EDB_CLUSTER_NAMESPACE=$NAMESPACE
        LOG_PATH=$K8S_NAMESPACES_EDB
        collectEDB
    fi

    #grab apicops mustgather
    MGMT=$(kubectl get mgmt -n $NAMESPACE 2>&1)
    if [[ $MGMT != *"No resources found"* ]]; then

        if [ -v APICOPS ]; then
            K8S_NAMESPACES_APICOPS_DATA="${K8S_NAMESPACES_SPECIFIC}/apicops"
            mkdir -p $K8S_NAMESPACES_APICOPS_DATA

            #List of apicops commands to be run for mustgather
            $APICOPS iss  -n $NAMESPACE > "${K8S_NAMESPACES_APICOPS_DATA}/iss.out"
            $APICOPS debug:info  -n $NAMESPACE > "${K8S_NAMESPACES_APICOPS_DATA}/debug-info.out"

        fi
    fi

    #grab daemonset data
    OUTPUT=`$KUBECTL get daemonset -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_DAEMONSET_DATA}/daemonsets.out"
        while read line; do
            ds=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe daemonset $ds -n $NAMESPACE &>"${K8S_NAMESPACES_DAEMONSET_DESCRIBE_DATA}/${ds}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DAEMONSET_DESCRIBE_DATA}/${ds}.out"

            $KUBECTL get daemonset $ds -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_DAEMONSET_YAML_OUTPUT}/${ds}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DAEMONSET_YAML_OUTPUT}/${ds}.yaml"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_DAEMONSET_DATA
    fi

    #grab deployment data
    OUTPUT=`$KUBECTL get deployments -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_DEPLOYMENT_DATA}/deployments.out"
        while read line; do
            deployment=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe deployment $deployment -n $NAMESPACE &>"${K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA}/${deployment}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA}/${deployment}.out"

            $KUBECTL get deployment $deployment -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_DEPLOYMENT_YAML_OUTPUT}/${deployment}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DEPLOYMENT_YAML_OUTPUT}/${deployment}.yaml"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_DEPLOYMENT_DATA
    fi

    #grab endpoint data
    OUTPUT=`$KUBECTL get endpoints -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ENDPOINT_DATA}/endpoints.out"
        while read line; do
            endpoint=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe endpoints $endpoint -n $NAMESPACE &>"${K8S_NAMESPACES_ENDPOINT_DESCRIBE_DATA}/${endpoint}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ENDPOINT_DESCRIBE_DATA}/${endpoint}.out"

            $KUBECTL get endpoints $endpoint -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_ENDPOINT_YAML_OUTPUT}/${endpoint}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ENDPOINT_YAML_OUTPUT}/${endpoint}.yaml"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ENDPOINT_DATA
    fi

    #grab job data
    OUTPUT=`$KUBECTL get jobs -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_JOB_DATA}/jobs.out"
        while read line; do
            job=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe job $job -n $NAMESPACE &> "${K8S_NAMESPACES_JOB_DESCRIBE_DATA}/${job}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_JOB_DESCRIBE_DATA}/${job}.out"

            $KUBECTL get job $job -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_JOB_YAML_OUTPUT}/${job}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_JOB_YAML_OUTPUT}/${job}.yaml"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_JOB_DATA
    fi

    #grab pgtasks data
    OUTPUT=`$KUBECTL get pgtasks -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0  ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_PGTASKS_DATA}/pgtasks.out"
        while read line; do
            pgtask=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe pgtask $pgtask -n $NAMESPACE &>"${K8S_NAMESPACES_PGTASKS_DESCRIBE_DATA}/${pgtask}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_PGTASKS_DESCRIBE_DATA}/${pgtask}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_PGTASKS_DATA
    fi

    #grab pod data
    OUTPUT=`$KUBECTL get pods -n $NAMESPACE -o wide 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_POD_DATA}/pods.out"
        while read line; do
            pod=`echo "$line" | awk -F ' ' '{print $1}'`
            if [[ "$pod" == "NAME" ]]; then
                continue
            fi
            echo "-- pod: $pod --"
            ready=`echo "$line" | awk -F ' ' '{print $2}' | awk -F'/' '{ print ($1==$2) ? "1" : "0" }'`
            status=`echo "$line" | awk -F ' ' '{print $3}'`
            node=`echo "$line" | awk -F ' ' '{print $7}'`

            IS_INGRESS=0
            IS_GATEWAY=0
            IS_PORTAL=0
            IS_ANALYTICS=0
            IS_EVENT=0

            subManager=""
            subAnalytics=""
            subPortal=""
            subGateway=""
            subEvent=""

            CHECK_INGRESS=0

            case $NAMESPACE in
                "kube-system")
                    case "$pod" in
                        *"calico"*|*"flannel"*) SUBFOLDER="networking";;
                        *"coredns"*) SUBFOLDER="coredns";;
                        *"etcd"*) SUBFOLDER="etcd";;
                        *"ingress"*)
                            IS_INGRESS=1
                            SUBFOLDER="ingress"
                            ;;
                        *"kube"*) SUBFOLDER="kube";;
                        *"metrics"*) SUBFOLDER="metrics";;
                        *"tiller"*) SUBFOLDER="tiller";;
                        *) SUBFOLDER="other";;
                    esac
                    DESCRIBE_TARGET_PATH="${K8S_NAMESPACES_POD_DESCRIBE_DATA}/${SUBFOLDER}"
                    LOG_TARGET_PATH="${K8S_NAMESPACES_POD_LOG_DATA}/${SUBFOLDER}";;
                *"rook"*)
                    DESCRIBE_TARGET_PATH="${K8S_NAMESPACES_POD_DESCRIBE_DATA}"
                    LOG_TARGET_PATH="${K8S_NAMESPACES_POD_LOG_DATA}";;
                *)
                    CHECK_INGRESS=1
                    case $pod in
                        "${SUBSYS_EVENT}"*)
                            SUBFOLDER="event"
                            ;;
                        *"${SUBSYS_MANAGER}"*|*"postgres"*)
                            SUBFOLDER="manager"
                            subManager=$SUBSYS_MANAGER
                            ;;
                        *"${SUBSYS_ANALYTICS}"*)
                            #This sometimes doesn't work due to truncation, see INSTANCE_LABEL below
                            SUBFOLDER="analytics"
                            subAnalytics=$SUBSYS_ANALYTICS
                            IS_ANALYTICS=1
                            ;;
                        *"${SUBSYS_PORTAL}"*)
                            SUBFOLDER="portal"
                            subPortal=$SUBSYS_PORTAL
                            IS_PORTAL=1
                            ;;
                        *"${SUBSYS_GATEWAY_V5}"*)
                            SUBFOLDER="gateway"
                            subGateway=$SUBSYS_GATEWAY_V5
                            IS_GATEWAY=1
                            ;;
                        "${SUBSYS_GATEWAY_V6}"*)
                            SUBFOLDER="gateway"
                            subGateway=$SUBSYS_GATEWAY_V6
                            IS_GATEWAY=1
                            ;;
                        *"datapower"*)
                            SUBFOLDER="gateway"
                            IS_GATEWAY=1
                            ;;
                        "ingress-nginx"*)
                            IS_INGRESS=1
                            SUBFOLDER="ingress"
                            ;;
                        *"ibm-apiconnect"*)
                            SUBFOLDER="operator"
                            ;;
                        *)
                            #check for multiple subsystems
                            for s in $SUBSYS_MANAGER; do
                                if [[ "${pod}" == "${s}-"* ]]; then
                                    SUBFOLDER="manager"
                                    subManager=$s
                                fi
                            done
                            for s in $SUBSYS_ANALYTICS; do
                                if [[ "${pod}" == "${s}-"* ]]; then
                                    SUBFOLDER="analytics"
                                    subAnalytics=$s
                                    IS_ANALYTICS=1
                                fi
                            done
                            for s in $SUBSYS_PORTAL; do
                                if [[ "${pod}" == "${s}-"* ]]; then
                                    SUBFOLDER="portal"
                                    subPortal=$s
                                    IS_PORTAL=1
                                fi
                            done
                            for s in $SUBSYS_GATEWAY_V5; do
                                if [[ "${pod}" == "${s}-"* ]]; then
                                    SUBFOLDER="gateway"
                                    subGateway=$s
                                    IS_GATEWAY=1
                                fi
                            done
                            for s in $SUBSYS_GATEWAY_V6; do
                                if [[ "${pod}" == "${s}-"* ]]; then
                                    SUBFOLDER="gateway"
                                    subGateway=$s
                                    IS_GATEWAY=1
                                fi
                            done
                            for s in $SUBSYS_EVENT; do
                                if [[ "${pod}" == "${s}-"* ]]; then
                                    SUBFOLDER="event"
                                    subEvent=$s
                                    IS_EVENT=1
                                fi
                            done
                            if [[ -z $SUBFOLDER ]]; then
                                SUBFOLDER="other"
                            fi
                    esac

                    # Following is to fix the case where analytics instance name is truncated.
                    INSTANCE_LABEL=`$KUBECTL get pod -n $NAMESPACE -o jsonpath='{.metadata.labels.app\.kubernetes\.io\/instance}' $pod 2>/dev/null`
                    if [[ $INSTANCE_LABEL == $SUBSYS_ANALYTICS ]]; then
                        SUBFOLDER="analytics"
                        subAnalytics=$SUBSYS_ANALYTICS
                        IS_ANALYTICS=1
                    fi

                    DESCRIBE_TARGET_PATH="${K8S_NAMESPACES_POD_DESCRIBE_DATA}/${SUBFOLDER}"
                    LOG_TARGET_PATH="${K8S_NAMESPACES_POD_LOG_DATA}/${SUBFOLDER}";;
            esac

            #make sure directories exist
            if [[ ! -d "$DESCRIBE_TARGET_PATH" ]]; then
                mkdir -p $DESCRIBE_TARGET_PATH
            fi
            if [[ ! -d "$LOG_TARGET_PATH" ]]; then
                mkdir -p $LOG_TARGET_PATH
            fi

            #grab ingress configuration
            if [[ $IS_INGRESS -eq 1 ]]; then
                $KUBECTL cp -n $NAMESPACE "${pod}:/etc/nginx/nginx.conf" "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" &>/dev/null
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out"

                #reset variable
                IS_INGRESS=0
            fi

            #grab postgres data
            if [[ $NOT_DIAG_MANAGER -eq 0 && $COLLECT_CRUNCHY -eq 1 && "$status" == "Running" && "$pod" == *"postgres"* && ! "$pod" =~ (backrest|pgbouncer|stanza|operator|backup) ]]; then
                echo "Collecting manager diagnostic data..."
                health_dir="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/postgres/${pod}-health-stats"

                mkdir -p $health_dir

                POSTGRES_PGLOGS_NAME=`$KUBECTL exec -n $NAMESPACE ${pod} -- ls -1 /pgdata 2>"/dev/null" | grep -v lost 2>"/dev/null"`
                POSTGRES_PGWAL_NAME=`$KUBECTL exec -n $NAMESPACE ${pod} -- ls -1 /pgwal 2>"/dev/null" | grep -v lost 2>"/dev/null"`

                #df
                DB_DF_OUTPUT=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- df -h 2>"/dev/null"`
                echo "$DB_DF_OUTPUT" > $health_dir/df.out

                #pg wal dir count
                PG_WAL_DIR_COUNT=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- ls -lrt /pgwal/${POSTGRES_PGWAL_NAME}/ | wc -l 2>"/dev/null"`
                echo "$PG_WAL_DIR_COUNT" > $health_dir/pgwal-dir-count.out

                #pg wal dir history data
                PG_WAL_HISTORY_LIST=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- ls -lrt /pgwal/${POSTGRES_PGWAL_NAME}/ | grep history 2>"/dev/null"`
                echo "$PG_WAL_HISTORY_LIST" > $health_dir/pgwal-history-list.out

                # pgdata du
                PG_DATA_DU_OUTPUT=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- du -sh /pgdata/${POSTGRES_PGLOGS_NAME}/  2>"/dev/null"`
                echo "$PG_DATA_DU_OUTPUT" > $health_dir/pgdata-du.out

                # pgdata du base
                PG_DATA_DU_BASE_OUTPUT=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- du -sh /pgdata/${POSTGRES_PGLOGS_NAME}/base/  2>"/dev/null"`
                echo "$PG_DATA_DU_BASE_OUTPUT" > $health_dir/pgdata-du-base.out

                # pgwal du
                PG_WAL_DU_OUTPUT=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- du -sh /pgwal/${POSTGRES_PGWAL_NAME}/  2>"/dev/null"`
                echo "$PG_WAL_DU_OUTPUT" > $health_dir/pgwal-du.out

                # patroniclt list
                PATRONICTL_LIST_OUTPUT=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- patronictl list 2>"/dev/null"`
                echo "$PATRONICTL_LIST_OUTPUT" > $health_dir/patronictl-list.out

                # patroniclt history
                PATRONICTL_HISTORY_OUTPUT=`$KUBECTL exec -n $NAMESPACE ${pod} -c database -- patronictl history 2>"/dev/null"`
                echo "$PATRONICTL_HISTORY_OUTPUT" > $health_dir/patronictl-history.out

                #SQL Commands
                QUERY1="select * from pg_stat_subscription"
                QUERY2="select relname,last_vacuum, last_autovacuum, last_analyze, last_autoanalyze from pg_stat_user_tables"
                QUERY3="select relname, n_dead_tup, last_autovacuum, autovacuum_count FROM pg_stat_sys_tables where relname = 'pg_class';"
                QUERY4="SELECT schemaname, relname, n_live_tup, n_dead_tup, last_autovacuum FROM pg_stat_all_tables ORDER BY n_dead_tup / (n_live_tup * current_setting('autovacuum_vacuum_scale_factor')::float8 + current_setting('autovacuum_vacuum_threshold')::float8) DESC LIMIT 10;"
                QUERY5="select * from pg_replication_slots"
                QUERY6="select * from pg_stat_replication"
                QUERY7="select * from pg_publication"
                QUERY8="select * from pg_stat_wal_receiver;"

                #Default postgres database
                POSTGRES_QUERIES=("QUERY1" "QUERY5" "QUERY6" "QUERY8" "QUERY2" "QUERY3" "QUERY4")
                for QUERY in "${POSTGRES_QUERIES[@]}"; do
                    QUERY_RUNNING="${!QUERY}"
                    echo "$QUERY_RUNNING" >> $health_dir/postgres-sql-queries.out
                    SQL_OUTPUT=`$KUBECTL exec -i ${pod} -- psql -c "$QUERY_RUNNING" 2>/dev/null </dev/null`
                    echo -e "$SQL_OUTPUT\n" >> $health_dir/postgres-sql-queries.out
                done

                #APIM Database
                APIM_QUERIES=("QUERY7" "QUERY2" "QUERY3" "QUERY4")
                for QUERY in "${APIM_QUERIES[@]}"; do
                    QUERY_RUNNING="${!QUERY}"
                    echo "$QUERY_RUNNING" >> $health_dir/apim-sql-queries.out
                    SQL_OUTPUT=`$KUBECTL exec -i ${pod} -- psql -d apim -c "$QUERY_RUNNING" 2>/dev/null </dev/null`
                    echo -e "$SQL_OUTPUT\n" >> $health_dir/apim-sql-queries.out
                done

                #LUR Database
                LUR_QUERIES=("QUERY7" "QUERY2" "QUERY3" "QUERY4")
                for QUERY in "${LUR_QUERIES[@]}"; do
                    QUERY_RUNNING="${!QUERY}"
                    echo "$QUERY_RUNNING" >> $health_dir/lur-sql-queries.out
                    SQL_OUTPUT=`$KUBECTL exec -i ${pod} -- psql -d lur -c "$QUERY_RUNNING" 2>/dev/null </dev/null`
                    echo -e "$SQL_OUTPUT\n" >> $health_dir/lur-sql-queries.out
                done

            fi

            PG_BACKREST_REPO_POD=$($KUBECTL -n "$NAMESPACE" get po -lpgo-backrest-repo=true,vendor=crunchydata -o=custom-columns=NAME:.metadata.name --no-headers)
            if [[ $NOT_DIAG_MANAGER -eq 0 && $COLLECT_CRUNCHY -eq 1 && "$status" == "Running" && "$pod" == "$PG_BACKREST_REPO_POD" ]]; then
                echo "Collecting manager diagnostic data..."
                target_dir="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/postgres/${pod}"
                mkdir -p "$target_dir"

                pg_cluster=$($KUBECTL -n "$NAMESPACE" get pgcluster -o=custom-columns=NAME:.metadata.name --no-headers)

                COMMAND1="pgbackrest info"
                COMMAND2="du -ksh /backrestrepo/$pg_cluster-backrest-shared-repo/backup"
                COMMAND3="du -ksh /backrestrepo/$pg_cluster-backrest-shared-repo/archive"
                COMMAND4="ls -ltr /backrestrepo/$pg_cluster-backrest-shared-repo/backup/db"
                COMMAND5="ls -ltr /backrestrepo/$pg_cluster-backrest-shared-repo/archive/db"
                COMMAND6="ls -ltrR /backrestrepo/$pg_cluster-backrest-shared-repo/archive/db/12-1"
                COMMAND7="ls -ltr /tmp"
                COMMAND8="tail -50 /tmp/db-backup.log"
                COMMAND9="tail -50 /tmp/db-expire.log"
                COMMAND10="ps -elf"

                BACKREST_COMMANDS=("COMMAND1" "COMMAND2" "COMMAND3" "COMMAND4" "COMMAND5" "COMMAND6" "COMMAND7" "COMMAND8" "COMMAND9" "COMMAND10")
                for COMMAND in "${BACKREST_COMMANDS[@]}"; do
                    COMMAND="${!COMMAND}"
                    echo -e "\nExecuting Command: $COMMAND" >> $target_dir/backrest-repo-details.out
                    OUTPUT=$($KUBECTL -n $NAMESPACE exec -i $pod -- $COMMAND  2>/dev/null </dev/null)
                    echo -e "$OUTPUT\n" >> $target_dir/backrest-repo-details.out
                done
            fi

            #grab gateway diagnostic data
            if [[ $NOT_DIAG_GATEWAY -eq 0 && $IS_GATEWAY -eq 1 && $ready -eq 1 && "$status" == "Running" && "$pod" != *"monitor"* && "$pod" != *"operator"* ]]; then
                echo "Collecting gateway diagnostic data..."
                GATEWAY_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/gateway/${pod}"
                mkdir -p $GATEWAY_DIAGNOSTIC_DATA

                #grab all "gwd-log.log" files
                GWD_FILE_LIST=`$KUBECTL exec -n $NAMESPACE ${pod} -- find /opt/ibm/datapower/drouter/temporary/log/apiconnect/ -name "gwd-log.log*"`
                echo "${GWD_FILE_LIST}" | while read fullpath; do
                    filename=$(basename $fullpath)
                    $KUBECTL cp -n $NAMESPACE ${pod}:${fullpath} "${GATEWAY_DIAGNOSTIC_DATA}/${filename}" &>/dev/null
                done

                #open SOMA port to localhost
                $KUBECTL port-forward ${pod} 5550:5550 -n ${NAMESPACE} 1>/dev/null 2>/dev/null &
                pid=$!
                #necessary to wait for port-forward to start
                sleep 1

                #write out XML to to file
                XML_PATH=$(mktemp)
                generateXmlForErrorReport "$XML_PATH"

                #POST XML to gateway, start error report creation
                admin_password="admin"
                secret_name=$($KUBECTL get DataPowerService $subGateway -n $NAMESPACE -o jsonpath='{.spec.users[?(@.name=="admin")].passwordSecret}')
                if [[ ${#secret_name} -gt 0 ]]; then
                    admin_password=`$KUBECTL -n $NAMESPACE get secret $secret_name -o jsonpath='{.data.password}' | base64 -d`
                fi

                response=`curl -k -X POST --write-out %{http_code} --silent --output /dev/null \
                    -u admin:${admin_password} \
                    -H "Content-Type: application/xml" \
                    -d "@${XML_PATH}" \
                    https://127.0.0.1:5550`

                #only proceed with error report if response status code is 200
                if [[ $response -eq 200 ]]; then

                    #pull error report
                    echo -e "Pausing for error report to generate..."
                    sleep $ERROR_REPORT_SLEEP_TIMEOUT

                    #this will give a link that points to the target error report
                    $KUBECTL cp -n $NAMESPACE "${pod}:/opt/ibm/datapower/drouter/temporary/error-report.txt.gz" "${GATEWAY_DIAGNOSTIC_DATA}/error-report.txt.gz" 1>/dev/null 2>"${GATEWAY_DIAGNOSTIC_DATA}/output.error"

                    #check error output for path to actual error report
                    REPORT_PATH=`cat "${GATEWAY_DIAGNOSTIC_DATA}/output.error" | awk -F'"' '{print $4}'`
                    if [[ -z "$REPORT_PATH" ]]; then
                        REPORT_PATH=`ls -l ${GATEWAY_DIAGNOSTIC_DATA} | grep error-report.txt.gz | awk -F' ' '{print $NF}'`
                        if [[ -n "$REPORT_PATH" ]]; then
                            #extract filename from path
                            REPORT_NAME=$(basename $REPORT_PATH)

                            #grab error report
                            $KUBECTL cp -n $NAMESPACE "${pod}:${REPORT_PATH}" "${GATEWAY_DIAGNOSTIC_DATA}/${REPORT_NAME}" &>/dev/null
                        fi

                        #remove link
                        rm -f "${GATEWAY_DIAGNOSTIC_DATA}/error-report.txt.gz"
                    else
                        #extract filename from path
                        REPORT_NAME=$(basename $REPORT_PATH)

                        #grab error report
                        $KUBECTL cp -n $NAMESPACE "${pod}:${REPORT_PATH}" "${GATEWAY_DIAGNOSTIC_DATA}/${REPORT_NAME}" &>/dev/null

                        #clean up
                        rm -f "${GATEWAY_DIAGNOSTIC_DATA}/output.error"
                    fi
                else
                    warning="WARNING! "
                    text="Received response code [${response}] while attempting to generate an error report on gateway.  Are calls to [127.0.0.1] being restricted?"
                    echo -e "${COLOR_YELLOW}${warning}${COLOR_WHITE}$text${COLOR_RESET}"
                fi

                #clean up
                kill -9 $pid
                wait $pid &>/dev/null
                rm -f $XML_PATH

                #reset variable
                IS_GATEWAY=0
            fi

            #grab analytics diagnostic data
            if [[ $NOT_DIAG_ANALYTICS -eq 0 && $IS_ANALYTICS -eq 1 && $ready -eq 1 && "$status" == "Running" ]]; then
                echo "Collecting analytics diagnostic data..."
                ANALYTICS_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/analytics/${pod}"
                mkdir -p $ANALYTICS_DIAGNOSTIC_DATA

                if [[ "$pod" == *"storage-"* ]]; then
                    OUTPUT1=`$KUBECTL exec -n $NAMESPACE $pod -- curl -ks --cert /etc/velox/certs/client/tls.crt --key /etc/velox/certs/client/tls.key "https://localhost:9200/_cluster/health?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cluster_health.out"
                    OUTPUT1=`$KUBECTL exec -n $NAMESPACE $pod -- curl -ks --cert /etc/velox/certs/client/tls.crt --key /etc/velox/certs/client/tls.key "https://localhost:9200/_cat/nodes?v"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cat_nodes.out"
                    OUTPUT1=`$KUBECTL exec -n $NAMESPACE $pod -- curl -ks --cert /etc/velox/certs/client/tls.crt --key /etc/velox/certs/client/tls.key "https://localhost:9200/_cat/indices?v"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cat_indices.out"
                    OUTPUT1=`$KUBECTL exec -n $NAMESPACE $pod -- curl -ks --cert /etc/velox/certs/client/tls.crt --key /etc/velox/certs/client/tls.key "https://localhost:9200/_cat/shards?v"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cat_shards.out"
                    OUTPUT1=`$KUBECTL exec -n $NAMESPACE $pod -- curl -ks --cert /etc/velox/certs/client/tls.crt --key /etc/velox/certs/client/tls.key "https://localhost:9200/_alias?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-alias.out"
                    OUTPUT1=`$KUBECTL exec -n $NAMESPACE $pod -- curl -ks --cert /etc/velox/certs/client/tls.crt --key /etc/velox/certs/client/tls.key "https://localhost:9200/_cluster/allocation/explain?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cluster_allocation_explain.out"
                elif [[ "$pod" == *"ingestion"* ]]; then
                    OUTPUT1=`$KUBECTL exec -n $NAMESPACE $pod -- curl -s "localhost:9600/_node/stats?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-node_stats.out"
                fi
            fi

            #write out pod descriptions
            $KUBECTL describe pod -n $NAMESPACE $pod &> "${DESCRIBE_TARGET_PATH}/${pod}.out"
            [ $? -eq 0 ] || rm -f "${DESCRIBE_TARGET_PATH}/${pod}.out"

            #write out logs
            for container in `$KUBECTL get pod -n $NAMESPACE $pod -o jsonpath="{.spec.containers[*].name}" 2>/dev/null`; do
                $KUBECTL logs -n $NAMESPACE $pod -c $container $LOG_LIMIT &> "${LOG_TARGET_PATH}/${pod}_${container}.log"
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_${container}.log" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_${container}.log"

                $KUBECTL logs --previous -n $NAMESPACE $pod -c $container $LOG_LIMIT &> "${LOG_TARGET_PATH}/${pod}_${container}_previous.log"
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_${container}_previous.log" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_${container}_previous.log"

                #grab portal data
                if [[ $NOT_DIAG_PORTAL -eq 0 && $IS_PORTAL -eq 1 && "$status" == "Running" ]]; then
                    echo "Collecting portal diagnostic data..."
                    PORTAL_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/portal/${pod}/${container}"

                    echo "${pod}" | grep -q "www"
                    if [[ $? -eq 0 ]]; then
                        case $container in
                            "admin")
                                mkdir -p $PORTAL_DIAGNOSTIC_DATA
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/list_sites -p" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/list_sites-platform.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/list_sites -d" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/list_sites-database.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/check_site -a" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/check_site-all.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/list_platforms" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/list_platforms.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "ls -lRAi --author --full-time" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/listing-all.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/status -u" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/status.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-pcpu" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/ps-cpu.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-rss | head -26" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/ps-rss.out"
                                ;;
                            "web")
                                ;;
                            *) ;;
                        esac
                    fi

                    echo "${pod}" | grep -q "db"
                    if [[ $? -eq 0 ]]; then
                        case $container in
                            "db")
                                mkdir -p $PORTAL_DIAGNOSTIC_DATA
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "mysqldump portal" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/portal.dump"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "ls -lRAi --author --full-time" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/listing-all.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-pcpu" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/ps-cpu.out"
                                OUTPUT1=`$KUBECTL exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-rss | head -26" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/ps-rss.out"
                                ;;
                            "dbproxy")
                                ;;
                            *) ;;
                        esac
                    fi
                fi
            done
        done <<< "$OUTPUT"

        #grab metric data
        if [[ $OUTPUT_METRICS -eq 0 ]]; then
            $KUBECTL top pods -n $NAMESPACE &> "${K8S_NAMESPACES_POD_DATA}/top.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_POD_DATA}/top.out"
        fi
    else
        rm -fr $K8S_NAMESPACES_POD_DATA
    fi

    #grab pvc data
    OUTPUT=`$KUBECTL get pvc -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0  ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_PVC_DATA}/pvc.out"
        while read line; do
            pvc=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe pvc $pvc -n $NAMESPACE &>"${K8S_NAMESPACES_PVC_DESCRIBE_DATA}/${pvc}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_PVC_DESCRIBE_DATA}/${pvc}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_PVC_DATA
    fi

    #grab replicaset data
    OUTPUT=`$KUBECTL get replicaset -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_REPLICASET_DATA}/replicasets.out"
        while read line; do
            rs=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe replicaset $rs -n $NAMESPACE &>"${K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA}/${rs}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA}/${rs}.out"

            $KUBECTL get replicaset $rs -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_REPLICASET_YAML_OUTPUT}/${rs}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_REPLICASET_YAML_OUTPUT}/${rs}.yaml"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_REPLICASET_DATA
    fi

    #grab role data
    OUTPUT=`$KUBECTL get roles -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ROLE_DATA}/roles.out"
        while read line; do
            role=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe role $role -n $NAMESPACE &> "${K8S_NAMESPACES_ROLE_DESCRIBE_DATA}/${role}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ROLE_DESCRIBE_DATA}/${role}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ROLE_DATA
    fi

    #grab rolebinding data
    OUTPUT=`$KUBECTL get rolebindings -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ROLEBINDING_DATA}/rolebindings.out"
        while read line; do
            rolebinding=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe rolebinding $rolebinding -n $NAMESPACE &> "${K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA}/${rolebinding}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA}/${rolebinding}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ROLEBINDING_DATA
    fi

    #grab role service account data
    OUTPUT=`$KUBECTL get serviceaccounts -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_SA_DATA}/serviceaccounts.out"
        while read line; do
            sa=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe sa $sa -n $NAMESPACE &> "${K8S_NAMESPACES_SA_DESCRIBE_DATA}/${sa}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SA_DESCRIBE_DATA}/${sa}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_SA_DATA
    fi

    #list all secrets
    OUTPUT=`$KUBECTL get secrets -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_SECRET_DATA}/secrets.out"

        #grab tls secrets and only the ca.crt and tls.crt fields, unless COLLECT_PRIVATE_KEYS is set
        OUTPUT=`$KUBECTL get secrets -n $NAMESPACE --field-selector type=kubernetes.io/tls 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            while read line; do
                secret=`echo "$line" | cut -d' ' -f1`

                # We can always describe the secret as there is no security exposure here
                $KUBECTL describe secret $secret -n $NAMESPACE &>"${K8S_NAMESPACES_SECRET_DESCRIBE_DATA}/${secret}.out"

                if [[ "$COLLECT_PRIVATE_KEYS" -eq 1 ]]; then
                    # Get entire secret
                    $KUBECTL get secret $secret -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_SECRET_YAML_OUTPUT}/${secret}.yaml"
                else
                    # Get only type, name, namespace, data["tls.crt"] and data["ca.crt"] fields
                    $KUBECTL get secret $secret -n $NAMESPACE -o jsonpath='type: {.type}{"\n"}metadata:{"\n"}  name: {.metadata.name}{"\n"}  namespace: {.metadata.namespace}{"\n"}data:{"\n"}  ca.crt: {.data.ca\.crt}{"\n"}  tls.crt: {.data.tls\.crt}{"\n"}' &>"${K8S_NAMESPACES_SECRET_YAML_OUTPUT}/${secret}.yaml"
                fi
                [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SECRET_YAML_OUTPUT}/${secret}.yaml"
            done <<< "$OUTPUT"
        fi
    else
        rm -fr $K8S_NAMESPACES_SECRET_DATA
    fi

    #grab service data
    OUTPUT=`$KUBECTL get svc -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_SERVICE_DATA}/services.out"
        while read line; do
            svc=`echo "$line" | cut -d' ' -f1`

            $KUBECTL describe svc $svc -n $NAMESPACE &>"${K8S_NAMESPACES_SERVICE_DESCRIBE_DATA}/${svc}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SERVICE_DESCRIBE_DATA}/${svc}.out"

            $KUBECTL get svc $svc -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_SERVICE_YAML_OUTPUT}/${svc}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SERVICE_YAML_OUTPUT}/${svc}.yaml"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_SERVICE_DATA
    fi

    #grab statefulset data
    OUTPUT=`$KUBECTL get sts -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_STS_DATA}/statefulset.out"
        while read line; do
            sts=`echo "$line" | cut -d' ' -f1`
            $KUBECTL describe sts $sts -n $NAMESPACE &> "${K8S_NAMESPACES_STS_DESCRIBE_DATA}/${sts}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_STS_DESCRIBE_DATA}/${sts}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_STS_DATA
    fi

    #^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ post processing ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    #transform portal data
    TARGET_DIRECTORY="${K8S_NAMESPACES_POD_LOG_DATA}/portal"
    CONTAINERS=(admin web)
    DIR_CONTENTS=`ls -A ${TARGET_DIRECTORY} 2>/dev/null`

    if [[ -d "${TARGET_DIRECTORY}" && ! -z "${DIR_CONTENTS}" ]]; then
        for container in ${CONTAINERS[@]}; do
            cd $TARGET_DIRECTORY

            if [[ SUBSYS_PORTAL_COUNT -gt 1 ]]; then
                for s in $SUBSYS_PORTAL; do
                    TRANSFORM_DIRECTORY="${TARGET_DIRECTORY}/transformed/${s}/${container}"
                    INTERLACED_LOG_FILE="${TRANSFORM_DIRECTORY}/logs_interlaced.out"

                    mkdir -p $TRANSFORM_DIRECTORY

                    LOG_FILES=`ls -1 $TARGET_DIRECTORY | egrep "${s}.*www.*${container}"`
                    grep . $LOG_FILES | sed 's/:\[/[ /' | sort -k5,6 >$INTERLACED_LOG_FILE

                    cd $tmpPortalPath
                    OUTPUT=`sed -E "s/\[([ a-z0-9_\-]*) std(out|err)].*/\1/" $INTERLACED_LOG_FILE | sed 's/^ *//' | awk -F ' ' '{print $NF}' | sort -u`
                    while read tag; do
                        grep "\[ *$tag " $INTERLACED_LOG_FILE >"${TRANSFORM_DIRECTORY}/${tag}.out"
                    done <<< "$OUTPUT"

                    rm -f $INTERLACED_LOG_FILE
                done
            else
                TRANSFORM_DIRECTORY="${TARGET_DIRECTORY}/transformed/${container}"
                INTERLACED_LOG_FILE="${TRANSFORM_DIRECTORY}/logs_interlaced.out"
                mkdir -p $TRANSFORM_DIRECTORY

                LOG_FILES=`ls -1 $TARGET_DIRECTORY | egrep "${SUBSYS_PORTAL}.*www.*${container}"`
                grep . $LOG_FILES | sed 's/:\[/[ /' | sort -k5,6 >$INTERLACED_LOG_FILE

                cd $TRANSFORM_DIRECTORY
                OUTPUT=`sed -E "s/\[([ a-z0-9_\-]*) std(out|err)].*/\1/" $INTERLACED_LOG_FILE | sed 's/^ *//' | awk -F ' ' '{print $NF}' | sort -u`
                while read tag; do
                    grep "\[ *$tag " $INTERLACED_LOG_FILE >"${TRANSFORM_DIRECTORY}/${tag}.out"
                done <<< "$OUTPUT"

                rm -f $INTERLACED_LOG_FILE
            fi
        done
    fi

#------------------------------------ Pull Data CP4i specific data ------------------------------------
    if [[ $IS_OCP ]]; then
        OCP_INSTALL_PLAN_DATA="${K8S_NAMESPACES_SPECIFIC}/install_plans"
        OCP_INSTALL_PLAN_DESCRIBE_DATA="${OCP_INSTALL_PLAN_DATA}/describe"
        OCP_INSTALL_PLAN_YAML_OUTPUT="${OCP_INSTALL_PLAN_DATA}/yaml"

        OCP_SUBSCRIPTION_DATA="${K8S_NAMESPACES_SPECIFIC}/subscriptions"
        OCP_SUBSCRIPTION_DESCRIBE_DATA="${OCP_SUBSCRIPTION_DATA}/describe"
        OCP_SUBSCRIPTION_YAML_OUTPUT="${OCP_SUBSCRIPTION_DATA}/yaml"

        OCP_CLUSTER_SERVICE_VERSION_DATA="${K8S_NAMESPACES_SPECIFIC}/cluster_service_version"
        OCP_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA="${OCP_CLUSTER_SERVICE_VERSION_DATA}/describe"
        OCP_CLUSTER_SERVICE_VERSION_YAML_OUTPUT="${OCP_CLUSTER_SERVICE_VERSION_DATA}/yaml"

        OCP_CATALOG_SOURCE_DATA="${K8S_NAMESPACES_SPECIFIC}/catalogsources"
        OCP_CATALOG_SOURCE_DATA_YAML_OUTPUT="${OCP_CATALOG_SOURCE_DATA}/yaml"

        mkdir -p $OCP_INSTALL_PLAN_DESCRIBE_DATA
        mkdir -p $OCP_INSTALL_PLAN_YAML_OUTPUT

        mkdir -p $OCP_SUBSCRIPTION_DESCRIBE_DATA
        mkdir -p $OCP_SUBSCRIPTION_YAML_OUTPUT

        mkdir -p $OCP_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA
        mkdir -p $OCP_CLUSTER_SERVICE_VERSION_YAML_OUTPUT

        mkdir -p $OCP_CATALOG_SOURCE_DATA_YAML_OUTPUT

        OUTPUT=`$KUBECTL get InstallPlan -n $NAMESPACE 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            echo "$OUTPUT" > "${OCP_INSTALL_PLAN_DATA}/install_plans.out"
            while read line; do
                ip=`echo "$line" | cut -d' ' -f1`
                $KUBECTL describe InstallPlan $ip -n $NAMESPACE &>"${OCP_INSTALL_PLAN_DESCRIBE_DATA}/${ip}.out"
                [ $? -eq 0 ] || rm -f "${OCP_INSTALL_PLAN_DESCRIBE_DATA}/${ip}.out"

                $KUBECTL get InstallPlan $ip -o yaml -n $NAMESPACE &>"${OCP_INSTALL_PLAN_YAML_OUTPUT}/${ip}.yaml"
                [ $? -eq 0 ] || rm -f "${OCP_INSTALL_PLAN_YAML_OUTPUT}/${ip}.yaml"
            done <<< "$OUTPUT"
        else
            rm -fr $OCP_INSTALL_PLAN_DATA
        fi

        OUTPUT=`$KUBECTL get Subscription -n $NAMESPACE 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            echo "$OUTPUT" > "${OCP_SUBSCRIPTION_DATA}/subscriptions.out"
            while read line; do
                sub=`echo "$line" | cut -d' ' -f1`
                $KUBECTL describe Subscription $sub -n $NAMESPACE &>"${OCP_SUBSCRIPTION_DESCRIBE_DATA}/${sub}.out"
                [ $? -eq 0 ] || rm -f "${OCP_SUBSCRIPTION_DESCRIBE_DATA}/${sub}.out"

                $KUBECTL get Subscription $sub -o yaml -n $NAMESPACE &>"${OCP_SUBSCRIPTION_YAML_OUTPUT}/${sub}.yaml"
                [ $? -eq 0 ] || rm -f "${OCP_SUBSCRIPTION_YAML_OUTPUT}/${sub}.yaml"
            done <<< "$OUTPUT"
        else
            rm -fr $OCP_SUBSCRIPTION_DATA
        fi

        OUTPUT=`$KUBECTL get ClusterServiceVersion -n $NAMESPACE 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            echo "$OUTPUT" > "${OCP_CLUSTER_SERVICE_VERSION_DATA}/cluster_service_version.out"
            while read line; do
                csv=`echo "$line" | cut -d' ' -f1`
                $KUBECTL describe ClusterServiceVersion $csv -n $NAMESPACE &>"${OCP_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA}/${csv}.out"
                [ $? -eq 0 ] || rm -f "${OCP_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA}/${csv}.out"

                $KUBECTL get ClusterServiceVersion $csv -o yaml -n $NAMESPACE &>"${OCP_CLUSTER_SERVICE_VERSION_YAML_OUTPUT}/${csv}.yaml"
                [ $? -eq 0 ] || rm -f "${OCP_CLUSTER_SERVICE_VERSION_YAML_OUTPUT}/${csv}.yaml"
            done <<< "$OUTPUT"
        else
            rm -fr $OCP_CLUSTER_SERVICE_VERSION_DATA
        fi

        OUTPUT=`$KUBECTL get catalogsource -n $NAMESPACE 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            echo "$OUTPUT" > "${OCP_CATALOG_SOURCE_DATA}/catalogsources.out"
            while read line; do
                cs=`echo "$line" | cut -d' ' -f1`
                $KUBECTL get catalogsource $cs -o yaml -n $NAMESPACE &>"${OCP_CATALOG_SOURCE_DATA_YAML_OUTPUT}/${cs}.yaml"
                [ $? -eq 0 ] || rm -f "${OCP_CATALOG_SOURCE_DATA_YAML_OUTPUT}/${cs}.yaml"
            done <<< "$OUTPUT"
        else
            rm -fr $OCP_CATALOG_SOURCE_DATA
        fi
    fi

#------------------------------------------------------------------------------------------------------

done
#------------------------------------------------------------------------------------------------------

#=================================================================================================================

#write out data to zip file
cd $TEMP_PATH
lc_ARCHIVE_UTILITY=`echo "${ARCHIVE_UTILITY}" | tr "[A-Z]" "[a-z]"`
if [[ "${lc_ARCHIVE_UTILITY}" == *"zip"* ]]; then
    ARCHIVE_FILE="${ARCHIVE_FILE}.zip"
    zip -rq $ARCHIVE_FILE .
else
    ARCHIVE_FILE="${ARCHIVE_FILE}.tgz"
    tar -cz -f $ARCHIVE_FILE .
fi

echo -e "Created [$ARCHIVE_FILE]."
exit 0
