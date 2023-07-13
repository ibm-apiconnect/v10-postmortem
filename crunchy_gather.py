#!/usr/bin/env python3
# pylint: disable=consider-using-with
# pylint: disable=C0209
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
        self.dir_name = (f"crunchy_k8s_support_dump_{time.strftime('%a-%Y-%m-%d-%H%M%S%z')}")


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
