# Gluster Persistent Volume Recycler for Openshift/Kubernetes

This repository contains an Ansible role for automatic installation of the
Gluster recycler, a program written by David McCormick.

As of OpenShift 3.9 there is no recycle plugin implemented for GlusterFS
persistent volumes. This is inconvenient--despite plans to write a fully
automated end-to-end provisioning plugin what do we do in the meantime to keep
our OpenShift installations with available storage?

The issue is that whenever a persistentVolumeClaim is created and then removed
it again rather than freeing up the storage, the volume goes into a failed
state instead with a message "no volume plugin matched" to protect from giving
the volume to someone else with data left on it.

The Gluster recycler is an interim work-around for while the offical gluster
recycler plugin remains unavailable.


## What does it do?

The Gluster recycler is a shell script running in a container which is given
access to the Kubernetes API and uses the GlusterFS FUSE client binaries for
mounting GlusterFS volumes. It runs in a loop (every 5 minutes by default)
getting a list of persistent volumes and examining their state. For each volume
that it finds in a failed state with the message "no volume plugin matched" or
in a released state without message it mounts it, removes all of the files, and
then deletes and re-creates the volume in OpenShift. This effectively recycles
the volume making it clean and available for use with new
persistentVolumeClaims.


## Service Account

The recycler script accesses the OpenShift API using the service account which
the pod/container was started with, and the preferred installation is to run it
with a special service account which has been appropriately provisioned so that
it can access and modify persistent volumes and nothing more.


## Privileged

The recycler container **must** unfortunately be run in privileged mode because
the FUSE client will not properly work without it. Also, it makes sense that
the recycler runs as root so that it has access to remove all the files that it
finds on the volumes which it is recycling.


## Requirements

* OpenShift Container Platform 3.9 or later
* OpenShift Origin 3.9 or later


## Role Variables

| Name                                  | Default value                                  | Description                                                          |
|---------------------------------------|------------------------------------------------|----------------------------------------------------------------------|
| appuio_gluster_recycler_repo          | https://github.com/appuio/gluster-recycler.git | Source repository to build the Gluster recycler from                 |
| appuio_gluster_recycler_repo_rev      | master                                         | Version of the Gluster recycler to build, i.e. Git ref of repo above |
| appuio_gluster_recycler_namespace     | appuio-infra                                   | Namespace to install Gluster recycler into                           |
| appuio_gluster_recycler_image         | None                                           | Image for recycler, uses image built on cluster by default           |
| appuio_gluster_recycler_gluster_hosts | None (required)                                | Semi-colon separated list of gluster hosts                           |
| appuio_gluster_recycler_schedule      | \*/5 \* \* \* \*                               | Execution schedule in cron format                                    |
| appuio_gluster_recycler_delay_seconds | 0                                              | Time in seconds to wait before recycling a volume after it failed    |
| appuio_gluster_recycler_timezone      | *appuio_container_timezone*, UTC               | Timezone of the container                                            |


## Dependencies

* <https://github.com/appuio/ansible-module-openshift>


## Example Usage

`playbook.yml`:

```yaml
roles:
- role: gluster-recycler
  appuio_gluster_recycler_gluster_hosts: gluster1.example.com;gluster2.example.com
  appuio_gluster_recycler_delay: "{{ 7 * 24 * 60 * 60 }}"  # 7 days
```
