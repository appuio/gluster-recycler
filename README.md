# Gluster Persistent Volume Recycler for Openshift/Kubernetes
 
At present there is no recycle plugin implemented for glusterfs persistent volumes in Openshift (I'm running Openshift 3.1.1) and I assume, upstream Kubernetes.  This is inconvenient - despite plans to write a fully automated end-to-end provisioing plugin what do we do in the meantime to keep our Openshift installations with available storage?  The issue is that whenever you create a persistentVolumeClaim and then remove it again rather than freeing up the storage, the volume goes into a failed state instead with a message "no volume plugin matched", presumably to protect you from giving the volume to someone else with files left on it.
 
The **gluster-recycler** docker container is an interim work-around for while the offical gluster recycler plugin remains unavailable.
 
## What does it do?
 
The gluster-recycler is at heart a simple shell script that runs in a container which is given access to the Kubernetes API and uses the glusterfs fuse client binaries for mounting glusterfs volumes.  It runs in a loop (every 5 minutes by default) getting a list of persistent volumes and examining their state.  For each volume that it finds in a failed state with the message "no volume plugin matched" it mounts it, removes all of the files, and then deletes and re-creates the volume in Kubernetes.  This effectively recycles the volume making it clean and available for use with new persistentVolumeClaims.
 
## Requirements
 
### Service Account
 
The recycler script accesses the Kubernetes API using the serviceaccount which the pod/container was started with, and the preferred installation is to run it with a special service account which has been appropriately provisioned so that it can access and modify persistent volumes and nothing more.
 
### Privileged
 
The recycler container **must** unfortunately be run in privileged mode because the fuse client will not properly work without it.  Also, it makes sense that the recycler runs as root so that it has access to remove all the files that it finds on the volumes which it is recycling.
 
## Installation
 
The easiest installation method on openshift is using the template here https://github.com/davemccormickig/gluster-recycler called 'recycler-setup-template.yaml'.
The temnplate will automatically create the following objects for you in Openshift: -
 
* serviceaccount
* clusterrole
* clusterrolebinding
* imagestream
* deploymentconfig
 
The template has the following parameters for customisation: -
 
| Parameter                | Usage                                                                                                         | Default                                    |
| ------------------------ | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| NAMESPACE (required)     | In order to create the clusterrolebinding we must inform the template which namespace you are installing into |                                            |
| GLUSTER_HOSTS (required) | A semi-colon separated list of your gluster hosts                                                             |                                            |
| INTERVAL                 | The time in seconds to wait between recycler runs.                                                            | 300                                        |
| DEBUG                    | Set to "true" in order to log more detail of recycler actions including API calls and responses.              | false                                      |
| IMAGE                    | Use an alternative gluster-recycler image than the one on dockerhub.                                          | docker.io/davemccormickig/gluster-recycler |
 
Before processing the template please add the service account 'gluster-recycler' to the privileged scc so that it can run containers in priviledged mode: -
 
```
oc edit scc privileged
(add this to the list of users)
system:serviceaccount:__your namespace__:gluster-recycler
```
Use the following oc command to process the template, substituting your NAMESPACE and GLUSTER_HOSTS e.g:-
 
```
oc process -f recycler-setup-template.yaml -v "NAMESPACE=openshift-infra,GLUSTER_HOSTS=glusterhost001;glusterhost002" | oc create -f -
serviceaccount "gluster-recycler" created
clusterrole "gluster-recycler" created
clusterrolebinding "gluster-recycler" created
imagestream "gluster-recycler" created
deploymentconfig "gluster-recycler" created
```
 
## Building the container
 
The gluster-recycler is a simple container, build from the upstream gluster-centos container (https://hub.docker.com/r/gluster/gluster-centos/)
We add the recycler.sh script and the jq binary which allows the script to manipulate json objects.
 
Build Dockerfile: -
```
FROM gluster/gluster-centos
ADD jq-linux64 /usr/bin/jq
ADD recycler.sh /
 
```
