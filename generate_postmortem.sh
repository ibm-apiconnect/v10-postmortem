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
for switch in $@; do
    case $switch in
        *"-h"*|*"--help"*)
            echo -e 'Usage: generate_postmortem.sh {optional: LOG LIMIT}'
            echo -e ""
            echo -e "Available switches:"
            echo -e "--extra-namespaces:      Extra namespaces separated with commas.  Example:  --extra-namespaces=dev1,dev2,dev3"
            echo -e "--log-limit:             Set the number of lines to collect from each pod logs."
            echo -e "--ova:                   Only set if running inside an OVA deployment."
            echo -e "--no-prompt:             Do not prompt to report auto-detected namespaces."
            echo -e "--pull-appliance-logs:   Call [apic logs] command then package into archive file."
            echo -e "--performance-check:     Set to run performance checks."
            echo -e "--no-history:            Do not collect user history."
            echo -e ""
            echo -e "--diagnostic-all:        Set to enable all diagnostic data."
            echo -e "--diagnostic-manager:    Set to include additional manager specific data."
            echo -e "--diagnostic-gateway:    Set to include additional gateway specific data."
            echo -e "--diagnostic-portal:     Set to include additional portal specific data."
            echo -e "--diagnostic-analytics:  Set to include additional portal specific data."
            echo -e ""
            echo -e "--debug:                 Set to enable verbose logging."
            echo -e ""
            exit 0
            ;;
        *"--debug"*)
            set -x
            DEBUG_SET=1
            ;;
        *"--ova"*)
            IS_OVA=1
            NO_PROMPT=1
            NAMESPACE_LIST="kube-system default"
            ;;
        *"--diagnostic-all"*)
            DIAG_MANAGER=1
            DIAG_GATEWAY=1
            DIAG_PORTAL=1
            DIAG_ANALYTICS=1
            ;;
        *"--diagnostic-manager"*)
            DIAG_MANAGER=1
            ;;
        *"--diagnostic-gateway"*)
            DIAG_GATEWAY=1
            ;;
        *"--diagnostic-portal"*)
            DIAG_PORTAL=1
            ;;
        *"--diagnostic-analytics"*)
            DIAG_ANALYTICS=1
            ;;
        *"--log-limit"*)
            limit=`echo "${switch}" | cut -d'=' -f2`
            if [[ "$limit" =~ ^[0-9]+$ ]]; then
                LOG_LIMIT="--tail=${limit}"
            fi
            ;;
        *"--extra-namespaces"*)
            NO_PROMPT=1
            extra_namespaces=`echo "${switch}" | cut -d'=' -f2 | tr ',' ' '`
            NAMESPACE_LIST="kube-system ${extra_namespaces}"
            ;;
        *"--pull-appliance-logs"*)
            PULL_APPLIANCE_LOGS=1
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
        *)
            if [[ -z "$DEBUG_SET" ]]; then
                set +e
            fi
            ;;
    esac
done

if [[ -z "$LOG_LIMIT" ]]; then
    LOG_LIMIT=""
fi

#====================================== Confirm pre-reqs and init variables ======================================
#------------------------------- Make sure all necessary commands exists ------------------------------
which kubectl &> /dev/null
if [[ $? -ne 0 ]]; then
    echo "Unable to locate the command [kubectl] in the path.  Either install or add it to the path.  EXITING..."
    exit 1
fi

ARCHIVE_UTILITY=`which zip 2>/dev/null`
if [[ $? -ne 0 ]]; then
    ARCHIVE_UTILITY=`which tar 2>/dev/null`
    if [[ $? -ne 0 ]]; then
        echo "Unable to locate either command [tar] / [zip] in the path.  Either install or add it to the path.  EXITING..."
        exit 1
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
    <dp:request xmlns:dp="http://www.datapower.com/schemas/management" domain="apiconnect">
      <dp:do-action>
        <ErrorReport/>
      </dp:do-action>
    </dp:request>
  </env:Body>
</env:Envelope>
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
MIN_KUBELET_VERSION="1.15"

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
kubectl get pods --all-namespaces 2>/dev/null | grep -q "metrics-server"
OUTPUT_METRICS=$?

kubectl get ns 2>/dev/null | grep -q "rook-ceph"
if [[ $? -eq 0 ]]; then
    NAMESPACE_LIST+=" rook-ceph"
fi

kubectl get ns 2>/dev/null | grep -q "rook-ceph-system"
if [[ $? -eq 0 ]]; then
    NAMESPACE_LIST+=" rook-ceph-system"
fi

#================================================= pull ova data =================================================
if [[ $IS_OVA -eq 1 ]]; then
    OVA_DATA="${TEMP_PATH}/ova"
    mkdir -p $OVA_DATA

    #grab version
    sudo apic version 1>"${OVA_DATA}/version.out" 2>/dev/null

    #grab status
    sudo apic status 1>"${OVA_DATA}/status.out" 2>/dev/null

    #grab bash history
    if [[ $NO_HISTORY -ne 1 ]]; then
        cp "/home/apicadm/.bash_history" "${OVA_DATA}/apicadm-bash_history.out" &>/dev/null
        cp "/root/.bash_history" "${OVA_DATA}/root-bash_history.out" &>/dev/null
    fi

    if [[ $PULL_APPLIANCE_LOGS -eq 1 ]]; then
        cd $OVA_DATA
        sudo apic logs &>/dev/null
    fi
fi
#=================================================================================================================

#============================================== autodetect namespaces ============================================
if [[ $AUTO_DETECT -eq 1 ]]; then
    NS_LISTING=`kubectl get ns 2>/dev/null | sed -e '1d' | egrep -v "kube-system|cert-manager|rook"`

    SUBSYS_MANAGER="ISNOTSET"
    SUBSYS_ANALYTICS="ISNOTSET"
    SUBSYS_PORTAL="ISNOTSET"
    SUBSYS_GATEWAY_V5="ISNOTSET"
    SUBSYS_GATEWAY_V6="ISNOTSET"

    CLUSTER_LIST=(ManagementCluster AnalyticsCluster PortalCluster GatewayCluster)
    ns_matches=""

    while read line; do
        ns=`echo "${line}" | awk '{print $1}'`

        for cluster in ${CLUSTER_LIST[@]}; do
            OUTPUT=`kubectl get -n $ns $cluster 2>/dev/null`
            if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
                OUTPUT=`echo "${OUTPUT}" | grep -v NAME`
                while read line; do
                    name=`echo ${line} | awk '{print $1}'`
                    
                    case $cluster in
                        "ManagementCluster")
                            SUBSYS_MANAGER=$name
                        ;;
                        "AnalyticsCluster")
                            SUBSYS_ANALYTICS=$name
                        ;;
                        "PortalCluster")
                            SUBSYS_PORTAL=$name
                        ;;
                        "GatewayCluster")
                            if [[ "$name" == *"v5"* ]]; then
                                SUBSYS_GATEWAY_V5=$name
                            else
                                SUBSYS_GATEWAY_V6=$name
                            fi
                        ;;
                    esac

                    if [[ "${ns_matches}" != *"${ns}"* ]]; then
                        ns_matches+=" ${ns}"
                    fi
                done <<< "$OUTPUT"
            fi
        done
    done <<< "$NS_LISTING"

    echo -e "Auto-detected namespaces [${ns_matches}]."

    if [[ $NO_PROMPT -ne 1 ]]; then
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

    NAMESPACE_LIST+=" ${ns_matches}"
fi
#=================================================================================================================

#============================================= pull kubernetes data ==============================================
#----------------------------------------- create directories -----------------------------------------
K8S_DATA="${TEMP_PATH}/kubernetes"

K8S_CLUSTER="${K8S_DATA}/cluster"
K8S_NAMESPACES="${K8S_DATA}/namespaces"
K8S_VERSION="${K8S_DATA}/versions"

K8S_CLUSTER_NODE_DATA="${K8S_CLUSTER}/nodes"
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


mkdir -p $K8S_VERSION

mkdir -p $K8S_CLUSTER_NODE_DATA
mkdir -p $K8S_CLUSTER_LIST_DATA
mkdir -p $K8S_CLUSTER_ROLE_DATA
mkdir -p $K8S_CLUSTER_ROLEBINDING_DATA

mkdir -p $K8S_CLUSTER_CRD_DESCRIBE_DATA
mkdir -p $K8S_CLUSTER_PV_DESCRIBE_DATA
mkdir -p $K8S_CLUSTER_STORAGECLASS_DESCRIBE_DATA

mkdir -p $K8S_CLUSTER_PERFORMANCE

#------------------------------------------------------------------------------------------------------

#grab kubernetes version
kubectl version 1>"${K8S_VERSION}/kubectl.version" 2>/dev/null

#----------------------------------- collect cluster specific data ------------------------------------
#node
OUTPUT=`kubectl get nodes 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" &> "${K8S_CLUSTER_NODE_DATA}/nodes.out"
    while read line; do
        name=`echo "$line" | awk -F ' ' '{print $1}'`
        role=`echo "$line" | awk -F ' ' '{print $3}'`

        describe_stdout=`kubectl describe node $name 2>/dev/null`
        if [[ $? -eq 0 && ${#describe_stdout} -gt 0 ]]; then
            if [[ -z "$role" ]]; then
                echo "$describe_stdout" > "${K8S_CLUSTER_NODE_DATA}/describe-${name}.out"
            else
                echo "$describe_stdout" > "${K8S_CLUSTER_NODE_DATA}/describe-${name}_${role}.out"
            fi

            if [[ -z "$ARCHIVE_FILE" && "$role" == *"master"* ]]; then
                host=`echo $name | cut -d'.' -f1`
                if [[ -z "$host" ]]; then
                    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${TIMESTAMP}"
                else
                    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${host}-${TIMESTAMP}"
                fi
            fi

            #check the docker / kubelet versions
            docker_version=`echo "$describe_stdout" | grep -i "Container Runtime Version" | awk -F'//' '{print $2}'`
            kubelet_version=`echo "$describe_stdout" | grep "Kubelet Version:" | awk -F' ' '{print $NF}' | awk -F'v' '{print $2}'`

            echo "$docker_version" >"${K8S_VERSION}/docker-${name}.version"

            version_gte $docker_version $MIN_DOCKER_VERSION
            if [[ $? -ne 0 ]]; then
                warning1="WARNING!  Node "
                warning2=" docker version [$docker_version] less than minimum [$MIN_DOCKER_VERSION]."
                echo -e "${COLOR_YELLOW}${warning1}${COLOR_WHITE}$name${COLOR_YELLOW}${warning2}${COLOR_RESET}"
                echo -e "${warning1}${name}${warning2}" >> "${K8S_DATA}/warnings.out"
            fi

            version_gte $kubelet_version $MIN_KUBELET_VERSION
            if [[ $? -ne 0 ]]; then
                warning1="WARNING!  Node "
                warning2=" kubelet version [$kubelet_version] less than minimum [$MIN_KUBELET_VERSION]."
                echo -e "${COLOR_YELLOW}${warning1}${COLOR_WHITE}$name${COLOR_YELLOW}${warning2}${COLOR_RESET}"
                echo -e "${warning1}${name}${warning2}" >> "${K8S_DATA}/warnings.out"
            fi
        fi
        
        
    done <<< "$OUTPUT"

    if [[ $OUTPUT_METRICS -eq 0 ]]; then
        kubectl top nodes &> "${K8S_CLUSTER_NODE_DATA}/top.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_NODE_DATA}/top.out"
    fi
else
    rm -fr $K8S_CLUSTER_NODE_DATA
fi

if [[ -z "$ARCHIVE_FILE" ]]; then
    ARCHIVE_FILE="${LOG_PATH}/apiconnect-logs-${TIMESTAMP}"
fi

#cluster roles
OUTPUT=`kubectl get clusterroles 2>/dev/null | cut -d' ' -f1`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    while read line; do
        kubectl describe clusterrole $line &> "${K8S_CLUSTER_ROLE_DATA}/${line}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_ROLE_DATA}/${line}.out"
    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_ROLE_DATA
fi

#cluster rolebindings
OUTPUT=`kubectl get clusterrolebindings 2>/dev/null | cut -d' ' -f1`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    while read line; do
        kubectl describe clusterrolebinding $line &> "${K8S_CLUSTER_ROLEBINDING_DATA}/${line}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_ROLEBINDING_DATA}/${line}.out"
    done <<< "$OUTPUT"
else
    rm -fr $K8S_CLUSTER_ROLEBINDING_DATA
fi

#crds
OUTPUT=`kubectl get crds 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_CRD_DATA}/crd.out"
    while read line; do
        crd=`echo "$line" | cut -d' ' -f1`
        kubectl describe crd $crd &>"${K8S_CLUSTER_CRD_DESCRIBE_DATA}/${crd}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_CRD_DESCRIBE_DATA}/${crd}.out"
    done <<< "$OUTPUT"
fi

#pv
OUTPUT=`kubectl get pv 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_PV_DATA}/pv.out"
    while read line; do
        pv=`echo "$line" | cut -d' ' -f1`
        kubectl describe pv $pv &>"${K8S_CLUSTER_PV_DESCRIBE_DATA}/${pv}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_PV_DESCRIBE_DATA}/${pv}.out"
    done <<< "$OUTPUT"
fi

#storageclasses
OUTPUT=`kubectl get storageclasses 2>/dev/null`
if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
    echo "$OUTPUT" > "${K8S_CLUSTER_STORAGECLASS_DATA}/storageclasses.out"
    while read $line; do
        sc=`echo "$line" | cut -d' ' -f1`
        kubectl describe storageclasses $sc &>"${K8S_CLUSTER_STORAGECLASS_DESCRIBE_DATA}/${sc}.out"
        [ $? -eq 0 ] || rm -f "${K8S_CLUSTER_STORAGECLASS_DESCRIBE_DATA}/${sc}.out"
    done <<< "$OUTPUT"
fi

#check etcd cluster performance
if [[ $PERFORMANCE_CHECK -eq 1 ]]; then
    if [[ $IS_OVA -eq 1 ]]; then
        apic stage etcd-check-perf -l debug &> ${K8S_CLUSTER_PERFORMANCE}/etcd-performance.out # ova has special `apic stage` command that will run the etcd performance check and a defrag after
    else
        ETCD_POD=`kubectl get pod -n kube-system --selector component=etcd -o=jsonpath={.items[0].metadata.name} 2>/dev/null` # retrieve name of etcd pod to exec
        # parse out etcd certs from pod describe
        ETCD_CA_FILE=`kubectl describe pod -n kube-system ${ETCD_POD} | grep "\--trusted-ca-file" | cut -f2 -d"=" 2>/dev/null`
        ETCD_CERT_FILE=`kubectl describe pod -n kube-system ${ETCD_POD} | grep "\--cert-file" | cut -f2 -d"=" 2>/dev/null`
        ETCD_KEY_FILE=`kubectl describe pod -n kube-system ${ETCD_POD} | grep "\--key-file" | cut -f2 -d"=" 2>/dev/null`
        
        OUTPUT=`kubectl exec -n kube-system ${ETCD_POD} -- sh -c "export ETCDCTL_API=3; etcdctl member list --cacert=${ETCD_CA_FILE} --cert=${ETCD_CERT_FILE} --key=${ETCD_KEY_FILE} 2>/dev/null"`
        
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
        OUTPUT=`kubectl exec -n kube-system ${ETCD_POD} -- sh -c "export ETCDCTL_API=3; etcdctl check perf --endpoints="${ENDPOINTS}" --cacert=${ETCD_CA_FILE} --cert=${ETCD_CERT_FILE} --key=${ETCD_KEY_FILE}"`
        echo "${OUTPUT}" > ${K8S_CLUSTER_PERFORMANCE}/etcd-performance.out

        # run recommeneded `etcdctl defrag` to free up storage space
        OUTPUT=`kubectl exec -n kube-system ${ETCD_POD} -- sh -c "export ETCDCTL_API=3; etcdctl defrag --endpoints="${ENDPOINTS}" --cacert=${ETCD_CA_FILE} --cert=${ETCD_CERT_FILE} --key=${ETCD_KEY_FILE}"`
        echo "${OUTPUT}" > ${K8S_CLUSTER_PERFORMANCE}/etcd-defrag.out
    fi
fi

#------------------------------------------------------------------------------------------------------

#---------------------------------- collect namespace specific data -----------------------------------
for NAMESPACE in $NAMESPACE_LIST; do

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
    
    K8S_NAMESPACES_POD_DATA="${K8S_NAMESPACES_SPECIFIC}/pods"
    K8S_NAMESPACES_POD_DESCRIBE_DATA="${K8S_NAMESPACES_POD_DATA}/describe"
    K8S_NAMESPACES_POD_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DATA}/diagnostic"
    K8S_NAMESPACES_POD_LOG_DATA="${K8S_NAMESPACES_POD_DATA}/logs"

    K8S_NAMESPACES_PVC_DATA="${K8S_NAMESPACES_SPECIFIC}/pvc"
    K8S_NAMESPACES_PVC_DESCRIBE_DATA="${K8S_NAMESPACES_PVC_DATA}/describe"

    K8S_NAMESPACES_REPLICASET_DATA="${K8S_NAMESPACES_SPECIFIC}/replicasets"
    K8S_NAMESPACES_REPLICASET_YAML_OUTPUT="${K8S_NAMESPACES_REPLICASET_DATA}/yaml"
    K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA="${K8S_NAMESPACES_REPLICASET_DATA}/describe"

    K8S_NAMESPACES_ROLE_DATA="${K8S_NAMESPACES_SPECIFIC}/roles"
    K8S_NAMESPACES_ROLE_DESCRIBE_DATA="${K8S_NAMESPACES_ROLE_DATA}/describe"

    K8S_NAMESPACES_ROLEBINDING_DATA="${K8S_NAMESPACES_SPECIFIC}/rolebindings"
    K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA="${K8S_NAMESPACES_ROLEBINDING_DATA}/describe"

    K8S_NAMESPACES_SA_DATA="${K8S_NAMESPACES_SPECIFIC}/service_accounts"
    K8S_NAMESPACES_SA_DESCRIBE_DATA="${K8S_NAMESPACES_SA_DATA}/describe"

    K8S_NAMESPACES_SERVICE_DATA="${K8S_NAMESPACES_SPECIFIC}/services"
    K8S_NAMESPACES_SERVICE_DESCRIBE_DATA="${K8S_NAMESPACES_SERVICE_DATA}/describe"
    K8S_NAMESPACES_SERVICE_YAML_OUTPUT="${K8S_NAMESPACES_SERVICE_DATA}/yaml"

    K8S_NAMESPACES_STS_DATA="${K8S_NAMESPACES_SPECIFIC}/statefulset"
    K8S_NAMESPACES_STS_DESCRIBE_DATA="${K8S_NAMESPACES_STS_DATA}/describe"

    mkdir -p $K8S_NAMESPACES_LIST_DATA

    mkdir -p $K8S_NAMESPACES_CLUSTER_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_CLUSTER_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_CRONJOB_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_DAEMONSET_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_DAEMONSET_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_DEPLOYMENT_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_ENDPOINT_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_ENDPOINT_YAML_OUTPUT

    mkdir -p $K8S_NAMESPACES_JOB_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_POD_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_POD_LOG_DATA

    mkdir -p $K8S_NAMESPACES_PVC_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_REPLICASET_YAML_OUTPUT
    mkdir -p $K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_ROLE_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_SA_DESCRIBE_DATA

    mkdir -p $K8S_NAMESPACES_SERVICE_DESCRIBE_DATA
    mkdir -p $K8S_NAMESPACES_SERVICE_YAML_OUTPUT

    mkdir -p $K8S_NAMESPACES_STS_DESCRIBE_DATA

    #grab cluster configuration, equivalent to "apiconnect-up.yml" which now resides in cluster
    CLUSTER_LIST=(ManagementCluster ManagementBackup ManagementRestore AnalyticsCluster PortalCluster GatewayCluster)
    for cluster in ${CLUSTER_LIST[@]}; do
        OUTPUT=`kubectl get -n $NAMESPACE $cluster 2>/dev/null`
        if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
            echo "${OUTPUT}" > "${K8S_NAMESPACES_CLUSTER_DATA}/${cluster}.out"

            kubectl describe $cluster -n $NAMESPACE &>"${K8S_NAMESPACES_CLUSTER_DESCRIBE_DATA}/${cluster}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CLUSTER_DESCRIBE_DATA}/${cluster}.out"

            kubectl get $cluster -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_CLUSTER_YAML_OUTPUT}/${cluster}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CLUSTER_YAML_OUTPUT}/${cluster}.yaml"
        fi
    done

    #grab lists
    OUTPUT=`kubectl get events -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/events.out"
    OUTPUT=`kubectl get secrets -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/secrets.out"
    OUTPUT=`kubectl get hpa -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/hpa.out"
    OUTPUT1=`kubectl get ingress -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT1} -gt 0 ]]; then
        echo "$OUTPUT1" > "${K8S_NAMESPACES_LIST_DATA}/ingress.out"

        #check each endpoint using nslookup
        if [[ ! -z "$PORTAL_NAMESPACE" && ! -z "$PORTAL_PODNAME" ]]; then
            echo -e  "\n\n----- Test for ingress endpoint DNS connectivity -----" >> "${K8S_NAMESPACES_LIST_DATA}/ingress.out"

            while read line; do
                ingress=`echo "$line" | awk -F' ' '{print $1}'`
                endpoint=`echo "$line" | awk -F' ' '{print $2}'`

                if [[ "$ingress" != "NAME" ]]; then
                    OUTPUT2=`kubectl exec -n $PORTAL_NAMESPACE -c admin $PORTAL_PODNAME -- nslookup $endpoint`
                    [[ ${#OUTPUT2} -eq 0 ]] || echo -e "$ nslookup ${endpoint}\n${OUTPUT2}\n\n" >> "${K8S_NAMESPACES_LIST_DATA}/ingress.out"
                fi
            done <<< "$OUTPUT1"
        fi
    fi

    #grab configmap data
    OUTPUT=`kubectl get configmaps -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_CONFIGMAP_DATA}/configmaps.out"
        while read line; do
            cm=`echo "$line" | cut -d' ' -f1`
            kubectl get configmap $cm -n $NAMESPACE -o yaml &>"${K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUT}/${cm}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CONFIGMAP_YAML_OUTPUTA}/${cm}.yaml"

            kubectl describe configmap $cm -n $NAMESPACE &> "${K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA}/${cm}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CONFIGMAP_DESCRIBE_DATA}/${cm}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_CONFIGMAP_DATA
    fi

    #grab cronjob data
    OUTPUT=`kubectl get cronjobs -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_CRONJOB_DATA}/cronjobs.out"
        while read line; do
            cronjob=`echo "$line" | cut -d' ' -f1`
            kubectl describe cronjob $cronjob -n $NAMESPACE &> "${K8S_NAMESPACES_CRONJOB_DESCRIBE_DATA}/${cronjob}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_CRONJOB_DESCRIBE_DATA}/${cronjob}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_CRONJOB_DATA
    fi

    #grab daemonset data
    OUTPUT=`kubectl get daemonset -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_DAEMONSET_DATA}/daemonset.out"
        while read line; do
            ds=`echo "$line" | cut -d' ' -f1`
            kubectl describe daemonset $ds -n $NAMESPACE &>"${K8S_NAMESPACES_DAEMONSET_DESCRIBE_DATA}/${ds}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DAEMONSET_DESCRIBE_DATA}/${ds}.out"

            kubectl get daemonset $ds -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_DAEMONSET_YAML_OUTPUT}/${ds}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DAEMONSET_YAML_OUTPUT}/${ds}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_DAEMONSET_DATA
    fi

    #grab deployment data
    OUTPUT=`kubectl get deployments -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_DEPLOYMENT_DATA}/deployments.out"
        while read line; do
            deployment=`echo "$line" | cut -d' ' -f1`
            kubectl describe deployment $deployment -n $NAMESPACE &>"${K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA}/${deployment}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA}/${deployment}.out"

            kubectl get deployment $deployment -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA}/${deployment}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_DEPLOYMENT_DESCRIBE_DATA}/${deployment}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_DEPLOYMENT_DATA
    fi

    #grab endpoint data
    OUTPUT=`kubectl get endpoints -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ENDPOINT_DATA}/endpoints.out"
        while read line; do
            endpoint=`echo "$line" | cut -d' ' -f1`
            kubectl describe endpoints $endpoint -n $NAMESPACE &>"${K8S_NAMESPACES_ENDPOINT_DESCRIBE_DATA}/${endpoint}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ENDPOINT_DESCRIBE_DATA}/${endpoint}.out"

            kubectl get endpoints $endpoint -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_ENDPOINT_YAML_OUTPUT}/${endpoint}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ENDPOINT_YAML_OUTPUT}/${endpoint}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ENDPOINT_DATA
    fi

    #grab job data
    OUTPUT=`kubectl get jobs -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_JOB_DATA}/jobs.out"
        while read line; do
            job=`echo "$line" | cut -d' ' -f1`
            kubectl describe job $job -n $NAMESPACE &> "${K8S_NAMESPACES_JOB_DESCRIBE_DATA}/${job}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_JOB_DESCRIBE_DATA}/${job}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_JOB_DATA
    fi

    #grab pod data
    NSLOOKUP_COMPLETE=0
    OUTPUT=`kubectl get pods -n $NAMESPACE -o wide 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_POD_DATA}/pods.out"
        while read line; do
            pod=`echo "$line" | awk -F ' ' '{print $1}'`
            ready=`echo "$line" | awk -F ' ' '{print $2}'`
            status=`echo "$line" | awk -F ' ' '{print $3}'`
            node=`echo "$line" | awk -F ' ' '{print $7}'`

            IS_INGRESS=0
            IS_GATEWAY=0
            IS_PORTAL=0
            IS_ANALYTICS=0

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
                        *"${SUBSYS_MANAGER}"*|*"postgres"*)
                            SUBFOLDER="manager"
                            ;;
                        *"${SUBSYS_ANALYTICS}"*)
                            SUBFOLDER="analytics"
                            IS_ANALYTICS=1
                            ;;
                        *"${SUBSYS_PORTAL}"*)
                            SUBFOLDER="portal"
                            IS_PORTAL=1
                            ;;
                        *"${SUBSYS_GATEWAY_V5}"*|"${SUBSYS_GATEWAY_V6}"*|*"datapower"*)
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
                            SUBFOLDER="other"
                    esac

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

            if [[ $NSLOOKUP_COMPLETE -eq 0 && $CHECK_INGRESS -eq 1 ]]; then
                if [[ ( "${pod}" == "${SUBSYS_MANAGER}-apim"* && "${pod}" != *"initschema"* ) || ( "${pod}" == "${SUBSYS_ANALYTICS}-client"* ) || ( "${pod}" == "${SUBSYS_PORTAL}-"*"www"* ) ]]; then
                    PERFORM_NSLOOKUP=1
                fi
                
                if [[ $PERFORM_NSLOOKUP -eq 1 ]]; then
                    #grab ingress or routes
                    ingress_list=`kubectl get ingress -n $NAMESPACE 2>/dev/null`
                    [ $? -eq 0 ] || ingress_list=`kubectl get routes -n $NAMESPACE 2>/dev/null`

                    ingress_list=`echo "${ingress_list}" | grep -v NAME | awk '{print $2}' | uniq`
                    at_start=1
                    while read ingress; do
                        nslookup_output=`kubectl exec -n $NAMESPACE $pod -- nslookup $ingress 2>&1`
                        if [[ $at_start -eq 1 ]]; then
                            echo -e "${nslookup_output}" > "${K8S_NAMESPACES_LIST_DATA}/ingress-checks.out"
                        else
                            echo -e "\n\n===============\n\n${nslookup_output}" >> "${K8S_NAMESPACES_LIST_DATA}/ingress-checks.out"
                        fi
                        at_start=0
                    done <<< "$ingress_list"

                    NSLOOKUP_COMPLETE=1
                fi

                PERFORM_NSLOOKUP=0
            fi

            #grab ingress configuration
            if [[ $IS_INGRESS -eq 1 ]]; then
                kubectl cp -n $NAMESPACE "${pod}:/etc/nginx/nginx.conf" "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" &>/dev/null
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out"

                #reset variable
                IS_INGRESS=0
            fi

            #grab postgres data
            if [[ $DIAG_MANAGER -eq 1 && "$pod" == *"postgres"* && ! "$pod" =~ (backrest|pgbouncer|stanza|operator) ]]; then
                target_dir="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/postgres/${pod}-debug"

                mkdir -p $target_dir
                POSTGRES_CLUSTER_NAME=`echo $pod | grep -o '[A-Za-z0-9\-]*postgres' 2>/dev/null`
                kubectl cp -n $NAMESPACE "${pod}:/pgdata/${POSTGRES_CLUSTER_NAME}/pglogs" $target_dir &>/dev/null
            fi

            #grab gateway diagnostic data
            if [[ $DIAG_GATEWAY -eq 1 && $IS_GATEWAY -eq 1 && "$ready" == "1/1" && "$status" == "Running" && "$pod" == "gwv"* && "$pod" != *"monitor"* ]]; then
                GATEWAY_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/gateway/${pod}"
                mkdir -p $GATEWAY_DIAGNOSTIC_DATA

                #grab gwd-log.log
                kubectl cp -n $NAMESPACE "${pod}:/opt/ibm/datapower/drouter/temporary/log/apiconnect/gwd-log.log" "${GATEWAY_DIAGNOSTIC_DATA}/gwd-log.log" &>/dev/null

                #open SOMA port to localhost
                kubectl port-forward ${pod} 5550:5550 -n ${NAMESPACE} 1>/dev/null 2>/dev/null &
                pid=$!
                #necessary to wait for port-forward to start
                sleep 1

                #write out XML to to file
                XML_PATH="${TEMP_PATH}/error_report.xml"
                generateXmlForErrorReport "$XML_PATH"

                #POST XML to gateway, start error report creation
                response=`curl -k -X POST --write-out %{http_code} --silent --output /dev/null \
                    -u admin:admin \
                    -H "Content-Type: application/xml" \
                    -d "@${XML_PATH}" \
                    https://127.0.0.1:5550`

                #only proceed with error report if response status code is 200
                if [[ $response -eq 200 ]]; then
                    
                    #pull error report
                    echo -e "Pausing for error report to generate..."
                    sleep $ERROR_REPORT_SLEEP_TIMEOUT

                    #this will give a link that points to the target error report
                    kubectl cp -n $NAMESPACE "${pod}:/opt/ibm/datapower/drouter/temporary/error-report.txt.gz" "${GATEWAY_DIAGNOSTIC_DATA}/error-report.txt.gz" 1>/dev/null 2>"${GATEWAY_DIAGNOSTIC_DATA}/output.error"

                    #check error output for path to actual error report
                    REPORT_PATH=`cat "${GATEWAY_DIAGNOSTIC_DATA}/output.error" | awk -F'"' '{print $4}'`
                    if [[ -z "$REPORT_PATH" ]]; then
                        REPORT_PATH=`ls -l ${GATEWAY_DIAGNOSTIC_DATA} | grep error-report.txt.gz | awk -F' ' '{print $NF}'`
                        if [[ -n "$REPORT_PATH" ]]; then
                            #extract filename from path
                            REPORT_NAME=$(basename $REPORT_PATH)

                            #grab error report
                            kubectl cp -n $NAMESPACE "${pod}:${REPORT_PATH}" "${GATEWAY_DIAGNOSTIC_DATA}/${REPORT_NAME}" &>/dev/null
                        fi

                        #remove link
                        rm -f "${GATEWAY_DIAGNOSTIC_DATA}/error-report.txt.gz"
                    else
                        #extract filename from path
                        REPORT_NAME=$(basename $REPORT_PATH)

                        #grab error report
                        kubectl cp -n $NAMESPACE "${pod}:${REPORT_PATH}" "${GATEWAY_DIAGNOSTIC_DATA}/${REPORT_NAME}" &>/dev/null

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
                rm -f $XML_PATH $SCRIPT_PATH

                #reset variable
                IS_GATEWAY=0
            fi

            #grab analytics diagnostic data
            if [[ $DIAG_ANALYTICS -eq 1 && $IS_ANALYTICS -eq 1 && "$ready" == "1/1" && "$status" == "Running" ]]; then
                ANALYTICS_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/analytics/${pod}"
                mkdir -p $ANALYTICS_DIAGNOSTIC_DATA

                if [[ "$pod" == *"storage-data"* || "$pod" == *"storage-basic"* ]]; then
                    OUTPUT1=`kubectl exec -n $NAMESPACE $pod -- curl_es -s "_cluster/health?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cluster_health.out"
                    OUTPUT1=`kubectl exec -n $NAMESPACE $pod -- curl_es -s "_cat/nodes?v"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cat_nodes.out"
                    OUTPUT1=`kubectl exec -n $NAMESPACE $pod -- curl_es -s "_cat/indices?v"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cat_indices.out"
                    OUTPUT1=`kubectl exec -n $NAMESPACE $pod -- curl_es -s "_cat/shards?v"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cat_shards.out"
                    OUTPUT1=`kubectl exec -n $NAMESPACE $pod -- curl_es -s "_alias?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-alias.out"
                    OUTPUT1=`kubectl exec -n $NAMESPACE $pod -- curl_es -s "_cluster/allocation/explain?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-cluster_allocation_explain.out"
                elif [[ "$pod" == *"ingestion"* ]]; then
                    OUTPUT1=`kubectl exec -n $NAMESPACE $pod -- curl -s "localhost:9600/_node/stats?pretty"`
                    echo "$OUTPUT1" >"${ANALYTICS_DIAGNOSTIC_DATA}/curl-node_stats.out"
                fi
            fi

            #write out pod descriptions
            kubectl describe pod -n $NAMESPACE $pod &> "${DESCRIBE_TARGET_PATH}/${pod}.out"
            [ $? -eq 0 ] || rm -f "${DESCRIBE_TARGET_PATH}/${pod}.out"

            #write out logs
            for container in `kubectl get pod -n $NAMESPACE $pod -o jsonpath="{.spec.containers[*].name}" 2>/dev/null`; do
                kubectl logs -n $NAMESPACE $pod -c $container $LOG_LIMIT &> "${LOG_TARGET_PATH}/${pod}_${container}.log"
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_${container}.log" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_${container}.log"

                kubectl logs --previous -n $NAMESPACE $pod -c $container $LOG_LIMIT &> "${LOG_TARGET_PATH}/${pod}_${container}_previous.log"
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_${container}_previous.log" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_${container}_previous.log"

                #grab portal data
                if [[ $DIAG_PORTAL -eq 1 && $IS_PORTAL -eq 1 && "$status" == "Running" ]]; then
                    PORTAL_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/portal/${pod}/${container}"

                    echo "${pod}" | grep -q "www"
                    if [[ $? -eq 0 ]]; then
                        case $container in
                            "admin")
                                mkdir -p $PORTAL_DIAGNOSTIC_DATA
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/list_sites -p" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/list_sites-platform.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/list_sites -d" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/list_sites-database.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/list_platforms" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/list_platforms.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "ls -lRAi --author --full-time" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/listing-all.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "/opt/ibm/bin/status -u" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/status.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-pcpu" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/ps-cpu.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-rss | head -26" 2>"/dev/null"`
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
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "mysqldump portal" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/portal.dump" 
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "ls -lRAi --author --full-time" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/listing-all.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-pcpu" 2>"/dev/null"`
                                echo "$OUTPUT1" >"${PORTAL_DIAGNOSTIC_DATA}/ps-cpu.out"
                                OUTPUT1=`kubectl exec -n $NAMESPACE -c $container $pod -- bash -ic "ps -efHww --sort=-rss | head -26" 2>"/dev/null"`
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
            kubectl top pods -n $NAMESPACE &> "${K8S_NAMESPACES_POD_DATA}/top.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_POD_DATA}/top.out"
        fi
    else
        rm -fr $K8S_NAMESPACES_POD_DATA
    fi

    #grab pvc data
    OUTPUT=`kubectl get pvc -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0  ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_PVC_DATA}/pvc.out"
        while read line; do
            pvc=`echo "$line" | cut -d' ' -f1`
            kubectl describe pvc $pvc -n $NAMESPACE &>"${K8S_NAMESPACES_PVC_DESCRIBE_DATA}/${pvc}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_PVC_DESCRIBE_DATA}/${pvc}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_PVC_DATA
    fi

    #grab replicaset data
    OUTPUT=`kubectl get replicaset -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_REPLICASET_DATA}/replicaset.out"
        while read line; do
            rs=`echo "$line" | cut -d' ' -f1`
            kubectl describe replicaset $rs -n $NAMESPACE &>"${K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA}/${rs}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_REPLICASET_DESCRIBE_DATA}/${rs}.out"

            kubectl get replicaset $rs -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_REPLICASET_YAML_OUTPUT}/${rs}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_REPLICASET_YAML_OUTPUT}/${rs}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_REPLICASET_DATA
    fi

    #grab role data
    OUTPUT=`kubectl get roles -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ROLE_DATA}/roles.out"
        while read line; do
            role=`echo "$line" | cut -d' ' -f1`
            kubectl describe role $role -n $NAMESPACE &> "${K8S_NAMESPACES_ROLE_DESCRIBE_DATA}/${role}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ROLE_DESCRIBE_DATA}/${role}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ROLE_DATA
    fi

    #grab rolebinding data
    OUTPUT=`kubectl get rolebindings -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_ROLEBINDING_DATA}/rolebindings.out"
        while read line; do
            rolebinding=`echo "$line" | cut -d' ' -f1`
            kubectl describe rolebinding $rolebinding -n $NAMESPACE &> "${K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA}/${rolebinding}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_ROLEBINDING_DESCRIBE_DATA}/${rolebinding}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_ROLEBINDING_DATA
    fi
    
    #grab role service account data
    OUTPUT=`kubectl get sa -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_SA_DATA}/sa.out"
        while read line; do
            sa=`echo "$line" | cut -d' ' -f1`
            kubectl describe sa $sa -n $NAMESPACE &> "${K8S_NAMESPACES_SA_DESCRIBE_DATA}/${sa}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SA_DESCRIBE_DATA}/${sa}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_SA_DATA
    fi

    #grab service data
    OUTPUT=`kubectl get svc -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_SERVICE_DATA}/services.out"
        while read line; do
            svc=`echo "$line" | cut -d' ' -f1`
            
            kubectl describe svc $svc -n $NAMESPACE &>"${K8S_NAMESPACES_SERVICE_DESCRIBE_DATA}/${svc}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SERVICE_DESCRIBE_DATA}/${svc}.out"

            kubectl get svc $svc -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_SERVICE_YAML_OUTPUT}/${svc}.yaml"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SERVICE_YAML_OUTPUT}/${svc}.yaml"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_SERVICE_DATA
    fi

    #grab statefulset data
    OUTPUT=`kubectl get sts -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_STS_DATA}/statefulset.out"
        while read line; do
            sts=`echo "$line" | cut -d' ' -f1`
            kubectl describe sts $sts -n $NAMESPACE &> "${K8S_NAMESPACES_STS_DESCRIBE_DATA}/${sts}.out"
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
        done
    fi
    #^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
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
