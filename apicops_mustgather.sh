#!/bin/bash

# Collecting the output of some some important debugging apicops commands

which apicops &> /dev/null
if [[ $? -eq 0 ]]; then
    APICOPS="apicops"
else
    if [[ ! -e /tmp/apicops  ]]; then
        echo -e "Downloading apicops......"
        APICOPS_LATEST_VERSION=$(curl -s https://api.github.com/repos/ibm-apiconnect/apicops/releases/latest | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p');
        wget -O /tmp/apicops https://github.com/ibm-apiconnect/apicops/releases/download/$APICOPS_LATEST_VERSION/apicops-v10-linux
        if [[ ! -e /tmp/apicops  ]]; then
            echo -e "Warning: Failed to download the apicops cli. Skipping to collect apicops debuggings commands output. Please download the latest release of apicops manually before running the postmortem script. commands: wget -O /tmp/apicops https://github.com/ibm-apiconnect/apicops/releases/download/${APICOPS_LATEST_VERSION}/apicops-v10-linux && chmod +x /tmp/apicops"
        else
            chmod +x /tmp/apicops
            APICOPS="/tmp/apicops"
        fi
    else 
        APICOPS="/tmp/apicops"
    fi
fi

if [ -v APICOPS ]; then
    LOG_PATH=$1
    NAMESPACE=$2

    #List of apicops commands to be run for mustgather
    $APICOPS iss  -n $NAMESPACE > "${LOG_PATH}/iss.out"
    $APICOPS debug:info  -n $NAMESPACE > "${LOG_PATH}/debug-info.out"

fi