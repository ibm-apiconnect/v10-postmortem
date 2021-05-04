#!/usr/bin/env python3

import argparse
import logging
import os
import re
import subprocess
import sys
import tarfile
import posixpath
import time
from collections import OrderedDict

if sys.version_info[0] < 3:
    print("Python 3 or a more recent version is required.")
    exit()

logger = logging.getLogger("crunchy_support")

output_dir = ""
dir_sep="/"
namespace = ""
kube_cli = "kubectl"
timestr = time.strftime("%Y%m%d-%H%M%S")
dir_name = "crunchy_k8s_support_dump_{}".format(timestr)

api_resources = [
    "pods",
    "ReplicaSet",
    "Deployment",
    "Services",
    "ConfigMap",
    "Routes",
    "Ingress",
    "pvc",
    "configmap",
    "pgreplicas",
    "pgclusters",
    "pgpolicies",
    "pgtasks"
]


def run(configured_namespace, configured_output_path):
    global output_dir, namespace

    if not configured_namespace or configured_namespace == "":
        logger.error("Namespace argument is null or empty")
        sys.exit()

    global timestr
    global dir_name

    if configured_output_path:
        output_dir=posixpath.join(configured_output_path, dir_name)
    else:
        output_dir=posixpath.join(posixpath.abspath(__file__), dir_name)

    try:
        os.makedirs(output_dir, exist_ok = True)
    except OSError as error:
        print(error)

    logger.info("Saving support dump files in "+output_dir);

    collect_kube_version()
    collect_namespace_info()
    collect_events()
    collect_api_resources()
    collect_pvc_details()
    collect_configmap_details()
    collect_pods_logs()
    collect_pg_logs()
    archive_files()


def collect_kube_version():
    cmd = kube_cli + " version "
    logger.debug("collecting kube version info: "+cmd);
    collect_helper(cmd, file_name="version.info", resource_name="version")


def collect_namespace_info():
    if kube_cli == "oc":
        cmd = kube_cli + " describe project "+namespace 
    else:
        cmd = kube_cli + " get namespace -o yaml "+namespace 

    logger.debug("collecting namespace info: "+cmd);
    collect_helper(cmd, file_name="namespace.info", resource_name="namespace-info")

def collect_pvc_list():
    cmd = kube_cli + " get pvc"
    collect_helper(cmd, file_name="pvc.list", resource_name="pvc-list")

def collect_pvc_details():
    cmd = kube_cli + " get pvc -o yaml"
    collect_helper(cmd, file_name="pvc.details", resource_name="pvc-details")

def collect_configmap_list():
    cmd = kube_cli + " get configmap"
    collect_helper(cmd, file_name="configmap.list", resource_name="configmap-list")

def collect_configmap_details():
    cmd = kube_cli + " get configmap -o yaml"
    collect_helper(cmd, file_name="configmap.details", resource_name="configmap-details")

def collect_events():
    global output_dir
    cmd = kube_cli + " get events {}".format(get_namespace_argument())
    collect_helper(cmd=cmd, file_name="events", resource_name="events")

def collect_api_resources():
    logger.info("Collecting API resources:")
    resources_out = OrderedDict()
    for resource in api_resources:
        if kube_cli == "kubectl" and resource == "Routes":
            continue
        output = run_kube_get(resource)
        if output:
            resources_out[resource] = run_kube_get(resource)
            logger.info("  + {}".format(resource))

    for entry, out in resources_out.items():
        with open(posixpath.join(output_dir, entry), "wb") as fp:
            fp.write(out)


def collect_pods_logs():
    """
        Collects all the pods logs from given namespace
    """
    global output_dir
    logger.info("Collecting pod's logs:")
    logs_dir = posixpath.join(output_dir, "pod_logs")
    os.makedirs(logs_dir, exist_ok = True)

    pods = get_pods()
    if not pods:
        logger.warning("Could not get pods list - skipping pods logs collection")
        return

    for pod in pods:
        containers = get_containers(pod)
        for cont in containers:
            container=cont.rstrip()
            cmd = kube_cli + " logs {} {} -c {}".format(get_namespace_argument(), pod, container)
            with open("{}/{}_{}.log".format(logs_dir, pod, container), "wb") as fp:
                p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                while True:
                    line = p.stdout.readline()
                    if line:
                        fp.write(line)
                    else:
                        break
            logger.info("  + {} container:{}".format(pod,container))

def collect_pg_logs():

    global output_dir
    logger.info("Collecting last 2 PG logs (This could take a while)")
    logs_dir = posixpath.join(output_dir, "pg_logs")
    os.makedirs(logs_dir, exist_ok = True)
    pods = get_pg_pods()
    if not pods:
        logger.warning("Could not get pods list - skipping pods logs collection")
        return

    for pod in pods:
        cmd = kube_cli + " exec -it {} -c database {} -- /bin/bash -c 'ls -d /pgdata/*/pglogs/* '".format(get_namespace_argument(), pod)
        p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        while True:
            line = p.stdout.readline()
            filename=os.path.basename(line).rstrip().decode('UTF-8')
            if line:
                tgt_folder = "{}/{}".format(logs_dir, pod)
                tgt_file = "{}/{}/{}".format(logs_dir, pod, filename)
                os.makedirs(tgt_folder, exist_ok = True)
                cmd = kube_cli + " cp -c database {} {}:{} {}".format(get_namespace_argument(), pod, line.rstrip().decode('UTF-8'), tgt_file)
                q = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                q.wait()
            else:
                break
        logger.info("  + {}".format(pod))


def archive_files():
    global dir_name
    archive_file_size = 0
    file_name = output_dir + ".tar.gz"

    with tarfile.open(file_name, "w|gz") as tar:
        tar.add(output_dir, arcname=dir_name)
    logger.info("Archived files into {}".format(file_name))

    rc, out = run_shell_command("rm -rf {}".format(output_dir))
    if rc:
        logger.warning("Failed to delete directory after archiving: {}".format(out))
    try:
        archive_file_size = os.stat(file_name).st_size
        if archive_file_size > 25*1024*1024:
            logger.warning("Archive file ({} bytes) may be too big to email.".format(archive_file_size))
            logger.warning("Please request file share link by emailing support@crunchydata.com")
        else:
            logger.info("Archive file size (bytes): {}".format(archive_file_size))
    except Exception as e:
        logger.warning("Archive file size: NA")
        return
    return 

def get_pods():
    """
        Returns list of pods names
    """
    cmd = kube_cli + " get pod {} -lvendor=crunchydata -o=custom-columns=NAME:.metadata.name --no-headers".format(get_namespace_argument())
    rc, out = run_shell_command(cmd)
    if rc == 0:
        return out.decode("utf-8").split("\n")[:-1]
    logger.warning("Failed to get pods: {}".format(out))


def get_pg_pods():
    """
        Returns list of pods names
    """
    cmd = kube_cli + " get pod {} -lpgo-pg-database=true,vendor=crunchydata -o=custom-columns=NAME:.metadata.name --no-headers".format(get_namespace_argument())
    rc, out = run_shell_command(cmd)
    if rc == 0:
        return out.decode("utf-8").split("\n")[:-1]
    logger.warning("Failed to get pods: {}".format(out))


def get_containers(pod_name):
    """
        Returns list of containers in a pod
    """
    cmd = kube_cli + " get pods {} {} --no-headers -o=custom-columns=CONTAINERS:.spec.containers[*].name".format(get_namespace_argument(),pod_name)
    rc, out = run_shell_command(cmd)
    if rc == 0:
        return out.decode("utf-8").split(",")
    logger.warning("Failed to get pods: {}".format(out))


def get_namespace_argument():
    global namespace
    if namespace:
        return "-n {}".format(namespace)
    return ""


def collect_helper(cmd, file_name, resource_name):
    global output_dir
    rc, out = run_shell_command(cmd)
    if rc:
        logger.warning("Error when running {}: {}".format(cmd, out))
        return
    path = posixpath.join(output_dir, file_name)
    with open(path, "wb") as fp:
        fp.write(out)
    logger.info("Collected {}".format(resource_name))


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
            logger.warning("Failed in shell command: {}, output: {}".format(cmd, ex.output))
        return ex.returncode, ex.output

    return 0, output


def run_kube_get(resource_type):
    cmd = kube_cli + " get {} {} -o yaml".format(resource_type, get_namespace_argument())
    rc, out = run_shell_command(cmd)
    if rc == 0:
        return out
    logger.warning("Failed to get {} resource: {}".format(resource_type, out))


def get_kube_cli():
    cmd = "which oc"
    rc, out = run_shell_command(cmd, False)
    if rc == 0:
        return "oc" 

    cmd = "which kubectl"
    rc, out = run_shell_command(cmd,False)
    if rc == 0:
        return "kubectl" 
    else:
        logger.error("kubernetes CLI not found")
        sys.exit()
        

def check_kube_access():
    if kube_cli == "oc":
        cmd = "oc whoami"
    else:
        cmd = "kubectl cluster-info" 

    rc, out = run_shell_command(cmd)
    return rc


if __name__ == "__main__":
    logger.setLevel(logging.INFO)
    logging.basicConfig(format='%(asctime)s - %(levelname)s - %(message)s')
    parser = argparse.ArgumentParser(description='Crunchy support dump collector',add_help=True)
    requiredNamed = parser.add_argument_group('required arguments')
    requiredNamed.add_argument('-n', '--namespace', required=True, action="store", type=str, help='kubernetes namespace to use to create crunchy support dump')
    requiredNamed.add_argument('-o', '--output_dir', required=True, action="store", type=str, help='path to use for support dump archive')
    results = parser.parse_args()
    logger.info("------------------------------------------------------------------------------")
    logger.info("Crunchy support dump collector")
    logger.info("NOTE: We gather metadata and pod logs only. (No data and k8s secrets)") 
    logger.info("------------------------------------------------------------------------------")
    namespace=results.namespace
    kube_cli = get_kube_cli()
    if check_kube_access() != 0:
        logger.error("Not connected to kubernetes cluster")
        sys.exit()
 
    run(results.namespace, results.output_dir)
