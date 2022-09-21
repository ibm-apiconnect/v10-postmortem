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
            echo -e ""
            echo -e "--specific-namespaces:   Target only the listed namespaces for the data collection."
            echo -e "--extra-namespaces:      Extra namespaces separated with commas.  Example:  --extra-namespaces=dev1,dev2,dev3"
            echo -e "--log-limit:             Set the number of lines to collect from each pod logs."
            echo -e "--no-prompt:             Do not prompt to report auto-detected namespaces."
            echo -e "--performance-check:     Set to run performance checks."
            echo -e "--no-history:            Do not collect user history."
            echo -e ""
            echo -e "--ova:                   Only set if running inside an OVA deployment."
            echo -e "--pull-appliance-logs:   Call [apic logs] command then package into archive file."
            echo -e ""
            echo -e "--collect-secrets:       Collect secrets from targeted namespaces.  Due to sensitivity of data, do not use unless requested by support."
            echo -e "--collect-crunchy:       Collect Crunchy mustgather."
            echo -e "--collect-edb:           Collect EDB mustgather."
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
            if [[ $EUID -ne 0 ]]; then
                echo "This script must be run as root." 
                exit 1
            fi

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
            EDB_CLUSTER_NAME=$(oc get cluster --all-namespaces -o=jsonpath='{.items[0].metadata.name}')
            if [[ -z "$EDB_CLUSTER_NAME" ]]; then
                COLLECT_CRUNCHY=1
                SCRIPT_LOCATION="`pwd`/crunchy_gather.py"
            else
                COLLECT_EDB=1
                SCRIPT_LOCATION="`pwd`/edb_mustgather.sh"
            fi 
            if [[ ! -f $SCRIPT_LOCATION ]]; then
                echo -e "Unable to locate script ${SCRIPT_LOCATION} in current directory.  Download from GitHub repository.  Exiting..."
                exit 1
            fi
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
        *"--specific-namespaces"*)
            NO_PROMPT=1
            SPECIFIC_NAMESPACES=1
            specific_namespaces=`echo "${switch}" | cut -d'=' -f2 | tr ',' ' '`
            NAMESPACE_LIST="${specific_namespaces}"
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
        *"--collect-secrets"*)
            COLLECT_SECRETS=1
            ;;
        *"--collect-crunchy"*)
            COLLECT_CRUNCHY=1
            SCRIPT_LOCATION="`pwd`/crunchy_gather.py"
            if [[ ! -f $SCRIPT_LOCATION ]]; then
                echo -e "Unable to locate script [crunchy_gather.py] in current directory.  Download from GitHub repository.  Exiting..."
                exit 1
            fi
            chmod +x $SCRIPT_LOCATION
            ;;
        *"--collect-edb"*)
            COLLECT_EDB=1
            SCRIPT_LOCATION="`pwd`/edb_mustgather.sh"
            if [[ ! -f $SCRIPT_LOCATION ]]; then
                echo -e "Unable to locate script [edb_mustgather.sh] in current directory.  Download from GitHub repository.  Exiting..."
                exit 1
            fi
            chmod +x $SCRIPT_LOCATION
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

if [[ -z "$NO_PROMPT" ]]; then
    NO_PROMPT=0
fi

if [[ -z "$SPECIFIC_NAMESPACES" ]]; then
    SPECIFIC_NAMESPACES=0
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
    <dp:request xmlns:dp="http://www.datapower.com/schemas/management" domain="default">
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
kubectl get pods --all-namespaces 2>/dev/null | egrep -q "metrics-server|openshift-monitoring"
OUTPUT_METRICS=$?

kubectl get ns 2>/dev/null | grep -q "rook-ceph"
if [[ $? -eq 0 && $SPECIFIC_NAMESPACES -ne 1 ]]; then
    NAMESPACE_LIST+=" rook-ceph"
fi

kubectl get ns 2>/dev/null | grep -q "rook-ceph-system"
if [[ $? -eq 0 && $SPECIFIC_NAMESPACES -ne 1 ]]; then
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

    #grab health-check
    sudo apic health-check 1>"${OVA_DATA}/health-check.out" 2>/dev/null

    #grab subsystem history
    sudo apic subsystem 1>"${OVA_DATA}/subsystem-history.out" 2>/dev/null

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
    if [[ $PULL_APPLIANCE_LOGS -eq 1 ]]; then
        cd $OVA_DATA
        sudo apic logs &>/dev/null
    fi

    #pull syslogs
    find "/var/log" -name "*syslog*" -exec cp '{}' "${OVA_DATA}/" \;
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
    

    while read line; do
        ns=`echo "${line}" | awk '{print $1}'`

        for cluster in ${CLUSTER_LIST[@]}; do
            OUTPUT=`kubectl get -n $ns $cluster 2>/dev/null`
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
                            fi
                        ;;
                        "AnalyticsCluster")
                            if [[ ${SUBSYS_ANALYTICS} == "ISNOTSET" ]]; then
                                SUBSYS_ANALYTICS=$name
                            else
                                SUBSYS_ANALYTICS+=" ${name}"
                            fi
                            ((SUBSYS_ANALYTICS_COUNT=SUBSYS_ANALYTICS_COUNT+1))
                        ;;
                        "PortalCluster")
                            if [[ "${event_name}" != "${EVENT_PREFIX}"* ]]; then
                                if [[ ${SUBSYS_PORTAL} == "ISNOTSET" ]]; then
                                    SUBSYS_PORTAL=$name
                                else
                                    SUBSYS_PORTAL+=" ${name}"
                                fi
                                ((SUBSYS_PORTAL_COUNT=SUBSYS_PORTAL_COUNT+1))
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
                            else
                                if [[ ${SUBSYS_GATEWAY_V6} == "ISNOTSET" ]]; then
                                    SUBSYS_GATEWAY_V6=$name
                                else
                                    SUBSYS_GATEWAY_V6+=" ${name}"
                                fi
                                ((SUBSYS_GATEWAY_V6_COUNT=SUBSYS_GATEWAY_V6_COUNT+1))
                            fi
                        ;;
                        "EventEndpointManager" | "EventGatewayCluster")
                            if [[ ${SUBSYS_EVENT} == "ISNOTSET" ]]; then
                                SUBSYS_EVENT=$event_name
                            else
                                SUBSYS_EVENT+=" ${event_name}"
                            fi
                            ((SUBSYS_EVENT_COUNT=SUBSYS_EVENT_COUNT+1))
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
    done <<< "$NS_LISTING"

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

    K8S_NAMESPACES_SA_DATA="${K8S_NAMESPACES_SPECIFIC}/service_accounts"
    K8S_NAMESPACES_SA_DESCRIBE_DATA="${K8S_NAMESPACES_SA_DATA}/describe"

    K8S_NAMESPACES_SECRET_DATA="${K8S_NAMESPACES_SPECIFIC}/secrets"
    K8S_NAMESPACES_SECRET_DESCRIBE_DATA="${K8S_NAMESPACES_SECRET_DATA}/describe"
    K8S_NAMESPACES_SECRET_YAML_OUTPUT="${K8S_NAMESPACES_SECRET_DATA}/yaml"

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

    #grab cluster configuration, equivalent to "apiconnect-up.yml" which now resides in cluster
    CLUSTER_LIST=(apic AnalyticsBackups AnalyticsClusters AnalyticsRestores APIConnectClusters DataPowerServices DataPowerMonitors EventEndpointManager EventGatewayClusters GatewayClusters ManagementBackups ManagementClusters ManagementDBUpgrades ManagementRestores NatsClusters NatsServiceRoles NatsStreamingClusters PGClusters PGPolicies PGReplicas PGTasks PortalBackups PortalClusters PortalRestores PortalSecretRotations)
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
    OUTPUT=`kubectl get hpa -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/hpa.out"
    OUTPUT=`kubectl get validatingwebhookconfiguration -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/validatingwebhookconfiguration.out"
    OUTPUT=`kubectl get mutatingwebhookconfiguration -n $NAMESPACE 2>/dev/null`
    [[ $? -ne 0 || ${#OUTPUT} -eq 0 ]] ||  echo "$OUTPUT" > "${K8S_NAMESPACES_LIST_DATA}/mutatingwebhookconfiguration.out"

    #grab ingress/routes then check each
    OUTPUT=`kubectl get ingress -n $NAMESPACE 2>/dev/null`
    if [[ ${#OUTPUT} -gt 0 ]]; then
        ir_outfile="ingress.out"
        ir_checks_outfile="ingress-checks.out"
        IS_OCP=0
    else
        OUTPUT=`kubectl get routes -n $NAMESPACE 2>/dev/null`
        ir_outfile="routes.out"
        ir_checks_outfile="routes-checks.out"
        IS_OCP=1
    fi

    IR_OUTFILE="${K8S_NAMESPACES_LIST_DATA}/${ir_outfile}"
    IR_CHECKS_OUTFILE="${K8S_NAMESPACES_LIST_DATA}/${ir_checks_outfile}"

    if [[ ${#OUTPUT} -gt 0 && ! -f $IR_OUTFILE && ! -f $IR_CHECKS_OUTFILE ]]; then
        echo "$OUTPUT" > $IR_OUTFILE

        #check if portal pods are available to use nslookup
        OUTPUT1=`kubectl get pods -n $NAMESPACE 2>/dev/null | egrep -v "up|downloads" | egrep "portal.*www|-apim-|-client-|-ui-" | head -n1`
        if [[ ${#OUTPUT} -gt 0 ]]; then
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
                nslookup_output=`kubectl exec -n $NAMESPACE $nslookup_pod -- nslookup $ingress 2>&1`
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

    #grab crunchy mustgather
    if [[ $COLLECT_CRUNCHY -eq 1 && "$NAMESPACE" != "kube-system" ]]; then
        $CURRENT_PATH/crunchy_gather.py -n $NAMESPACE -l 5 -c kubectl -o $K8S_NAMESPACES_CRUNCHY_DATA &> "${K8S_NAMESPACES_CRUNCHY_DATA}/crunchy-collect.log"
    fi

    #grab edb mustgather
    if [[ $COLLECT_EDB -eq 1 && "$NAMESPACE" != "kube-system" ]]; then
        $CURRENT_PATH/edb_mustgather.sh $NAMESPACE $K8S_NAMESPACES_EDB
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

            kubectl get job $job -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_JOB_YAML_OUTPUT}/${job}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_JOB_YAML_OUTPUT}/${job}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_JOB_DATA
    fi

    #grab pgtasks data
    OUTPUT=`kubectl get pgtasks -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0  ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_PGTASKS_DATA}/pgtasks.out"
        while read line; do
            pgtask=`echo "$line" | cut -d' ' -f1`
            kubectl describe pgtask $pgtask -n $NAMESPACE &>"${K8S_NAMESPACES_PGTASKS_DESCRIBE_DATA}/${pgtask}.out"
            [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_PGTASKS_DESCRIBE_DATA}/${pgtask}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $K8S_NAMESPACES_PGTASKS_DATA
    fi

    #grab pod data
    OUTPUT=`kubectl get pods -n $NAMESPACE -o wide 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_POD_DATA}/pods.out"
        while read line; do
            pod=`echo "$line" | awk -F ' ' '{print $1}'`
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
                            if [[ SUBSYS_MANAGER_COUNT -gt 1 ]]; then
                                for s in $SUBSYS_MANAGER; do
                                    if [[ "${pod}" == "${s}-"* ]]; then
                                        SUBFOLDER="manager"
                                        subManager=$s
                                    fi
                                done
                            elif [[ SUBSYS_ANALYTICS_COUNT -gt 1 ]]; then
                                for s in $SUBSYS_ANALYTICS; do
                                    if [[ "${pod}" == "${s}-"* ]]; then
                                        SUBFOLDER="analytics"
                                        subAnalytics=$s
                                        IS_ANALYTICS=1
                                    fi
                                done
                            elif [[ SUBSYS_PORTAL_COUNT -gt 1 ]]; then
                                for s in $SUBSYS_PORTAL; do
                                    if [[ "${pod}" == "${s}-"* ]]; then
                                        SUBFOLDER="portal"
                                        subPortal=$s
                                        IS_PORTAL=1
                                    fi
                                done
                            elif [[ SUBSYS_GATEWAY_V5_COUNT -gt 1 ]]; then
                                for s in $SUBSYS_GATEWAY_V5; do
                                    if [[ "${pod}" == "${s}-"* ]]; then
                                        SUBFOLDER="gateway"
                                        subGateway=$s
                                        IS_GATEWAY=1
                                    fi
                                done
                            elif [[ SUBSYS_GATEWAY_V6_COUNT -gt 1 ]]; then
                                for s in $SUBSYS_GATEWAY_V6; do
                                    if [[ "${pod}" == "${s}-"* ]]; then
                                        SUBFOLDER="gateway"
                                        subGateway=$s
                                        IS_GATEWAY=1
                                    fi
                                done
                            elif [[ SUBSYS_EVENT_COUNT -gt 1 ]]; then
                                for s in $SUBSYS_EVENT; do
                                    if [[ "${pod}" == "${s}-"* ]]; then
                                        SUBFOLDER="event"
                                        subEvent=$s
                                        IS_EVENT=1
                                    fi
                                done
                            else
                                SUBFOLDER="other"
                            fi
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

            #grab ingress configuration
            if [[ $IS_INGRESS -eq 1 ]]; then
                kubectl cp -n $NAMESPACE "${pod}:/etc/nginx/nginx.conf" "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" &>/dev/null
                [[ $? -eq 0 && -s "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out" ]] || rm -f "${LOG_TARGET_PATH}/${pod}_nginx-ingress-configuration.out"

                #reset variable
                IS_INGRESS=0
            fi

            #grab postgres data
            if [[ $DIAG_MANAGER -eq 1 && "$status" == "Running" && "$pod" == *"postgres"* && ! "$pod" =~ (backrest|pgbouncer|stanza|operator) ]]; then
                target_dir="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/postgres/${pod}-pglogs"
                health_dir="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/postgres/${pod}-health-stats"

                mkdir -p $target_dir
                mkdir -p $health_dir

                POSTGRES_PGLOGS_NAME=`kubectl exec -n $NAMESPACE ${pod} -- ls -1 /pgdata 2>"/dev/null" | grep -v lost 2>"/dev/null"`
                POSTGRES_PGWAL_NAME=`kubectl exec -n $NAMESPACE ${pod} -- ls -1 /pgwal 2>"/dev/null" | grep -v lost 2>"/dev/null"`

                #pglogs
                kubectl cp -n $NAMESPACE "${pod}:/pgdata/${POSTGRES_PGLOGS_NAME}/pglogs" $target_dir &>/dev/null

                #df
                DB_DF_OUTPUT=`kubectl exec -n $NAMESPACE ${pod} -c database -- df -h 2>"/dev/null"`
                echo "$DB_DF_OUTPUT" > $health_dir/df.out
                
                #pg wal dir count
                PG_WAL_DIR_COUNT=`kubectl exec -n $NAMESPACE ${pod} -c database -- ls -lrt /pgwal/${POSTGRES_PGWAL_NAME}/ | wc -l 2>"/dev/null"`
                echo "$PG_WAL_DIR_COUNT" > $health_dir/pgwal-dir-count.out

                #pg wal dir history data
                PG_WAL_HISTORY_LIST=`kubectl exec -n $NAMESPACE ${pod} -c database -- ls -lrt /pgwal/${POSTGRES_PGWAL_NAME}/ | grep history 2>"/dev/null"`
                echo "$PG_WAL_HISTORY_LIST" > $health_dir/pgwal-history-list.out

                # pgdata du
                PG_DATA_DU_OUTPUT=`kubectl exec -n $NAMESPACE ${pod} -c database -- du -sh /pgdata/${POSTGRES_PGLOGS_NAME}/  2>"/dev/null"`
                echo "$PG_DATA_DU_OUTPUT" > $health_dir/pgdata-du.out

                # pgwal du
                PG_WAL_DU_OUTPUT=`kubectl exec -n $NAMESPACE ${pod} -c database -- du -sh /pgwal/${POSTGRES_PGWAL_NAME}/  2>"/dev/null"`
                echo "$PG_WAL_DU_OUTPUT" > $health_dir/pgwal-du.out
            fi

            #grab gateway diagnostic data
            if [[ $DIAG_GATEWAY -eq 1 && $IS_GATEWAY -eq 1 && $ready -eq 1 && "$status" == "Running" && "$pod" != *"monitor"* && "$pod" != *"operator"* ]]; then
                GATEWAY_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/gateway/${pod}"
                mkdir -p $GATEWAY_DIAGNOSTIC_DATA

                #grab all "gwd-log.log" files
                GWD_FILE_LIST=`kubectl exec -n $NAMESPACE ${pod} -- find /opt/ibm/datapower/drouter/temporary/log/apiconnect/ -name "gwd-log.log*"`
                echo "${GWD_FILE_LIST}" | while read fullpath; do
                    filename=$(basename $fullpath)
                    kubectl cp -n $NAMESPACE ${pod}:${fullpath} "${GATEWAY_DIAGNOSTIC_DATA}/${filename}" &>/dev/null
                done

                #open SOMA port to localhost
                kubectl port-forward ${pod} 5550:5550 -n ${NAMESPACE} 1>/dev/null 2>/dev/null &
                pid=$!
                #necessary to wait for port-forward to start
                sleep 1

                #write out XML to to file
                XML_PATH="${TEMP_PATH}/error_report.xml"
                generateXmlForErrorReport "$XML_PATH"

                #POST XML to gateway, start error report creation
                admin_password="admin"
                secret_name=`kubectl get pods -n $NAMESPACE ${pod} -o jsonpath='{range .spec.volumes[*]}{.secret.secretName}{"\n"}{end}' | grep admin`
                if [[ ${#secret_name} -gt 0 ]]; then
                    admin_password=`kubectl get secret $secret_name -o jsonpath='{.data.password}' | base64 -d`
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
            if [[ $DIAG_ANALYTICS -eq 1 && $IS_ANALYTICS -eq 1 && $ready -eq 1 && "$status" == "Running" ]]; then
                ANALYTICS_DIAGNOSTIC_DATA="${K8S_NAMESPACES_POD_DIAGNOSTIC_DATA}/analytics/${pod}"
                mkdir -p $ANALYTICS_DIAGNOSTIC_DATA

                if [[ "$pod" == *"storage-data"* || "$pod" == *"storage-basic"* || "$pod" == *"storage-shared"* ]]; then 
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

    #grab secrets
    OUTPUT=`kubectl get secrets -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT1} -gt 0 ]]; then
        echo "$OUTPUT" > "${K8S_NAMESPACES_SECRET_DATA}/secrets.out"

        if [[ $COLLECT_SECRETS -eq 1 ]]; then
            while read line; do
                secret=`echo "$line" | cut -d' ' -f1`

                kubectl describe secret $secret -n $NAMESPACE &>"${K8S_NAMESPACES_SECRET_DESCRIBE_DATA}/${secret}.out"
                [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SECRET_DESCRIBE_DATA}/${secret}.out"

                kubectl get secret $secret -o yaml -n $NAMESPACE &>"${K8S_NAMESPACES_SECRET_YAML_OUTPUT}/${secret}.yaml"
                [ $? -eq 0 ] || rm -f "${K8S_NAMESPACES_SECRET_YAML_OUTPUT}/${secret}.yaml"

            done <<< "$OUTPUT"
        else
            rm -fr $K8S_NAMESPACES_SECRET_DESCRIBE_DATA
            rm -fr $K8S_NAMESPACES_SECRET_YAML_OUTPUT
        fi
    else
        rm -fr $K8S_NAMESPACES_SECRET_DATA
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
    #^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
done
#------------------------------------------------------------------------------------------------------

#------------------------------------ Pull Data CP4i specific data ------------------------------------
NAMESPACE="ibm-common-services"
kubectl get ns $NAMESPACE &>/dev/null
if [[ $? -eq 0 ]]; then
    ICS_NAMESPACE="${K8S_NAMESPACES}/ibm-common-services"

    ICS_INSTALL_PLAN_DATA="${ICS_NAMESPACE}/install_plans"
    ICS_INSTALL_PLAN_DESCRIBE_DATA="${ICS_INSTALL_PLAN_DATA}/describe"
    ICS_INSTALL_PLAN_YAML_OUTPUT="${ICS_INSTALL_PLAN_DATA}/yaml"

    ICS_SUBSCRIPTION_DATA="${ICS_NAMESPACE}/subscriptions"
    ICS_SUBSCRIPTION_DESCRIBE_DATA="${ICS_SUBSCRIPTION_DATA}/describe"
    ICS_SUBSCRIPTION_YAML_OUTPUT="${ICS_SUBSCRIPTION_DATA}/yaml"

    ICS_CLUSTER_SERVICE_VERSION_DATA="${ICS_NAMESPACE}/cluster_service_version"
    ICS_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA="${ICS_CLUSTER_SERVICE_VERSION_DATA}/describe"
    ICS_CLUSTER_SERVICE_VERSION_YAML_OUTPUT="${ICS_CLUSTER_SERVICE_VERSION_DATA}/yaml"

    mkdir -p $ICS_INSTALL_PLAN_DESCRIBE_DATA
    mkdir -p $ICS_INSTALL_PLAN_YAML_OUTPUT

    mkdir -p $ICS_SUBSCRIPTION_DESCRIBE_DATA
    mkdir -p $ICS_SUBSCRIPTION_YAML_OUTPUT

    mkdir -p $ICS_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA
    mkdir -p $ICS_CLUSTER_SERVICE_VERSION_YAML_OUTPUT

    OUTPUT=`kubectl get InstallPlan -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${ICS_INSTALL_PLAN_DATA}/install_plans.out"
        while read line; do
            ip=`echo "$line" | cut -d' ' -f1`
            kubectl describe InstallPlan $ip -n $NAMESPACE &>"${ICS_INSTALL_PLAN_DESCRIBE_DATA}/${ip}.out"
            [ $? -eq 0 ] || rm -f "${ICS_INSTALL_PLAN_DESCRIBE_DATA}/${ip}.out"

            kubectl get InstallPlan $ip -o yaml -n $NAMESPACE &>"${ICS_INSTALL_PLAN_YAML_OUTPUT}/${ip}.out"
            [ $? -eq 0 ] || rm -f "${ICS_INSTALL_PLAN_YAML_OUTPUT}/${ip}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $ICS_INSTALL_PLAN_DATA
    fi

    OUTPUT=`kubectl get Subscription -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${ICS_SUBSCRIPTION_DATA}/subscriptions.out"
        while read line; do
            sub=`echo "$line" | cut -d' ' -f1`
            kubectl describe Subscription $sub -n $NAMESPACE &>"${ICS_SUBSCRIPTION_DESCRIBE_DATA}/${sub}.out"
            [ $? -eq 0 ] || rm -f "${ICS_SUBSCRIPTION_DESCRIBE_DATA}/${sub}.out"

            kubectl get Subscription $sub -o yaml -n $NAMESPACE &>"${ICS_SUBSCRIPTION_YAML_OUTPUT}/${sub}.out"
            [ $? -eq 0 ] || rm -f "${ICS_SUBSCRIPTION_YAML_OUTPUT}/${sub}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $ICS_INSTALL_PLAN_DATA
    fi

    OUTPUT=`kubectl get ClusterServiceVersion -n $NAMESPACE 2>/dev/null`
    if [[ $? -eq 0 && ${#OUTPUT} -gt 0 ]]; then
        echo "$OUTPUT" > "${ICS_CLUSTER_SERVICE_VERSION_DATA}/cluster_service_version.out"
        while read line; do
            csv=`echo "$line" | cut -d' ' -f1`
            kubectl describe ClusterServiceVersion $csv -n $NAMESPACE &>"${ICS_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA}/${csv}.out"
            [ $? -eq 0 ] || rm -f "${ICS_CLUSTER_SERVICE_VERSION_DESCRIBE_DATA}/${csv}.out"

            kubectl get ClusterServiceVersion $csv -o yaml -n $NAMESPACE &>"${ICS_CLUSTER_SERVICE_VERSION_YAML_OUTPUT}/${csv}.out"
            [ $? -eq 0 ] || rm -f "${ICS_CLUSTER_SERVICE_VERSION_YAML_OUTPUT}/${csv}.out"
        done <<< "$OUTPUT"
    else
        rm -fr $ICS_INSTALL_PLAN_DATA
    fi
fi
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