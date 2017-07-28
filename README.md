# Gluster Persistent Volume Recycler for Openshift/Kubernetes
 
At present there is no recycle plugin implemented for glusterfs persistent volumes in Openshift (I'm running Openshift 3.1.1) and I assume, upstream Kubernetes.  This is inconvenient - despite plans to write a fully automated end-to-end provisioing plugin what do we do in the meantime to keep our Openshift installations with available storage?  The issue is that whenever you create a persistentVolumeClaim and then remove it again rather than freeing up the storage, the volume goes into a failed state instead with a message "no volume plugin matched", presumably to protect you from giving the volume to someone else with files left on it.
 
The **gluster-recycler** docker container is an interim work-around for while the offical gluster recycler plugin remains unavailable.
 
## What does it do?
 
The gluster-recycler is at heart a simple shell script that runs in a container which is given access to the Kubernetes API and uses the glusterfs fuse client binaries for mounting glusterfs volumes.  It runs in a loop (every 5 minutes by default) getting a list of persistent volumes and examining their state.  For each volume that it finds in a failed state with the message "no volume plugin matched" it mounts it, removes all of the files, and then deletes and re-creates the volume in Kubernetes.  This effectively recycles the volume making it clean and available for use with new persistentVolumeClaims.
 
## Requirements
 
#### Service Account
 
The recycler script accesses the Kubernetes API using the serviceaccount which the pod/container was started with, and the preferred installation is to run it with a special service account which has been appropriately provisioned so that it can access and modify persistent volumes and nothing more.
 
#### Privileged
 
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
| DELAY                    | The time in seconds to wait before recycling a volume after it failed.                                        | 0                                          |
| DEBUG                    | Set to "true" in order to log more detail of recycler actions including API calls and responses.              | false                                      |
| IMAGE                    | Use an alternative gluster-recycler image than the one on dockerhub.                                          | docker.io/davemccormickig/gluster-recycler |
| SOURCE_REPO              | Source Repo for recycler                                                                                      |                                            |
 
Before processing the template please add the service account 'gluster-recycler' to the privileged scc so that it can run containers in priviledged mode: -
 
```
$ oc edit scc privileged
(add this to the list of users)
system:serviceaccount:__your namespace__:gluster-recycler
```
Use the following oc command to process the template, substituting your NAMESPACE and GLUSTER_HOSTS e.g:-
 
```
$ oc process -f recycler-setup-template.yaml -v "NAMESPACE=openshift-infra,GLUSTER_HOSTS=glusterhost001;glusterhost002" | oc create -f -
serviceaccount "gluster-recycler" created
clusterrole "gluster-recycler" created
clusterrolebinding "gluster-recycler" created
imagestream "gluster-recycler" created
deploymentconfig "gluster-recycler" created
```
 
## Example run
 
Lets create a PersistentVolumeClaim
 
```
$ cat <<EOT
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-claim
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 3G
EOT | oc create -f -
persistentvolumeclaim "test-claim" created
```
 
It is bound to a persistent volume: -
 
```
$ oc get pvc test-claim -o yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  creationTimestamp: 2016-04-23T15:26:09Z
  name: test-claim
  namespace: infrastructure-builders
  resourceVersion: "9440128"
  selfLink: /api/v1/namespaces/infrastructure-builders/persistentvolumeclaims/test-claim
  uid: b4281e0e-0967-11e6-8f57-0050568f7a94
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 3G
  volumeName: glsvol-5g-0020
status:
  accessModes:
  - ReadWriteMany
  capacity:
    storage: 5Gi
  phase: Bound

$ oc get pv glsvol-5g-0020 -o yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  creationTimestamp: 2016-04-14T08:58:16Z
  name: glsvol-5g-0020
  resourceVersion: "9440129"
  selfLink: /api/v1/persistentvolumes/glsvol-5g-0020
  uid: 06e2c463-021f-11e6-933b-0050568f9ceb
spec:
  accessModes:
  - ReadWriteMany
  capacity:
    storage: 5Gi
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: test-claim
    namespace: infrastructure-builders
    resourceVersion: "9440125"
    uid: b4281e0e-0967-11e6-8f57-0050568f7a94
  glusterfs:
    endpoints: glusterfs-cluster
    path: glsvol-5g-0020
  persistentVolumeReclaimPolicy: Recycle
status:
  phase: Bound
```
 
Now if we remove our claim the persistent volume goes into a failed state: -
 
```
$ oc delete pvc test-claim
persistentvolumeclaim "test-claim" deleted
 
$ oc get pv glsvol-5g-0020 -o yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  creationTimestamp: 2016-04-14T08:58:16Z
  name: glsvol-5g-0020
  resourceVersion: "9440304"
  selfLink: /api/v1/persistentvolumes/glsvol-5g-0020
  uid: 06e2c463-021f-11e6-933b-0050568f9ceb
spec:
  accessModes:
  - ReadWriteMany
  capacity:
    storage: 5Gi
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: test-claim
    namespace: infrastructure-builders
    resourceVersion: "9440125"
    uid: b4281e0e-0967-11e6-8f57-0050568f7a94
  glusterfs:
    endpoints: glusterfs-cluster
    path: glsvol-5g-0020
  persistentVolumeReclaimPolicy: Recycle
status:
  message: no volume plugin matched
  phase: Failed
```
 
Watching the logs on the gluster-recycler container shows the volume being picked up and recycled: -
 
```
97 persistent volumes found
*****
Attempting to re-cycle volume glsvol-5g-0020
*****
WARNING: getfattr not found, certain checks will be skipped..
Successfully mounted volume glsvol-5g-0020 to /mnt
Recreating volume glsvol-5g-0020 in kubernetes...
Successfully re-cycled volume glsvol-5g-0020
Finished recycle run
```
 
The volume is now available for re-use: -
 
```
$ oc get pv glsvol-5g-0020 -o yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  creationTimestamp: 2016-04-23T15:33:32Z
  name: glsvol-5g-0020
  resourceVersion: "9440467"
  selfLink: /api/v1/persistentvolumes/glsvol-5g-0020
  uid: bcbc7ba7-0968-11e6-8b2d-0050568f56a5
spec:
  accessModes:
  - ReadWriteMany
  capacity:
    storage: 5Gi
  glusterfs:
    endpoints: glusterfs-cluster
    path: glsvol-5g-0020
  persistentVolumeReclaimPolicy: Recycle
status:
  phase: Available
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

## Ansible Role

This repository contains an Ansible role for automatic installation of the Gluster recycler.

### Requirements

One of:

* OpenShift Enterprise 3.2
* OpenShift Container Platform 3.3 or later
* OpenShift Origin M5 1.3 or later.

### Role Variables

| Name          | Default value                                              | Description                                                            |
|---------------|------------------------------------------------------------|------------------------------------------------------------------------|
| src           | *role_src*, https://github.com/appuio/gluster-recycler.git | Source repository to from the Gluster recycler from                    |
| version       | *role_version*, master                                     | Version of the Gluster recycler to build, i.e. Git ref of repo above   |
| namespace     | appuio-infra                                               | namespace to install Gluster recycler into                             |
| gluster_hosts | None (Required)                                            | Semi-colon separated list of gluster hosts                             |
| interval      | 300                                                        | The time in seconds to wait between recycler runs.                     |
| delay         | 0                                                          | The time in seconds to wait before recycling a volume after it failed. |
| timezone      | *appuio_container_timezone*, UTC                           | Timezone of the container                                              |

In case of multiple default values the first defined value is used.

### Dependencies

* <https://github.com/appuio/ansible-module-openshift>

### Example Usage

`playbook.yml`:

```yaml
roles:
- role: gluster-recycler
  gluster_hosts: gluster1.example.com;gluster2.example.com
  delay: "{{ 7 * 24 * 60 * 60 }}"  # 7 days
```
