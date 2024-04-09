# v10-postmortem tool: apic-mustgather

> [!NOTE]  
> We are transitioning to the **`apic-mustgather`** tool presented in this page. 
> The `generate_postmortem.sh` and related scripts are deprecated but still available at this time, see [deprecated README](README_deprecated.md)

## Pre-Requisites

- **Python3 v3.6 or later**
- **kubectl** or **oc** must be available on PATH. Alternatively location may be specified with `--kube-cli` argument.
- The **kubectl-cnp** plugin should be pre-installed if EDB is deployed. If not present, user will be prompted to allow an attempt to set it up.
- **apicops** should be present on PATH if apicops output is to be included. If not present, user will be prompted to allow an attempt to download the latest version.

> Note: on all APIConnect VMware Appliances, all the above pre-requisites are satisfied, except for `apicops`.

## Deployment Instructions

1.  Download the tool using the following command:
```shell
curl -L -O https://github.com/ibm-apiconnect/v10-postmortem/releases/latest/download/apic-mustgather
```
2.  Add execution permissions to file using the command `chmod +x apic-mustgather`.
3.  Run the tool using the command **`./apic-mustgather`**.

> Note: Only for APIC Appliances/OVA, first connect to the target appliance via SSH then switch to the _root user_ by running the command `sudo -i`.

## Notes
- For usage information with the tool, use the command `./apic-mustgather --help`
- While the postmortem collection tool is running, it is expected that the CPU and I/O load for the APIC deployment and its host cluster/VM will be increased.
- To reduce load on the host cluster/VM, the argument `--sequential` can be used, with the tradeof that log collection will be slower.

## Need help?
-  Open a ticket with IBM Support in the IBM API Connect product
-  If you do not have access to IBM Support, report an issue to submit any feedback
