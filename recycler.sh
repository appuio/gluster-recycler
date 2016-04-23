#!/bin/bash
#
# Glusterfs volume recycler for use with Kubernetes
# Copyright 2016 David McCormick
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
# In an endless loop: -
# Retreives a list of persistentvolumes from kubernetes and for each glusterfs volume in a failed state:
#  mount volume
#  remove all contents
#  delete and re-add the volume
 
#####################################################################################
# Inputs are ENVIRONMENT VARIABLES
#
# CLUSTER - the address string of the gluster cluster, e.g.
# INTERVAL - the pause between recyle runs (default 5 minutes)
# DEBUG - set to 'true' to enable detailed logging.
 
CAOPTS="-k"
JQ="jq -c -M -r"
 
echo "glusterfs recycler is starting up"
 
# Check we can find the Kubernetes service
if [[ "${KUBERNETES_SERVICE_HOST}" == "" || "${KUBERNETES_SERVICE_PORT}" == "" ]]; then
  echo "ERROR! The recycler needs to be able to find the Kubernetes API from the variables KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT."
  echo "Are you running this container via Kubernetes/Openshift?  You can pass these as environment variables if you need to."
  exit 1
fi
 
# Check that we have access to jq
if [[ ! -e "/usr/bin/jq" && ! -e "/usr/local/bin/jq" ]]; then
  echo "ERROR! The recycler needs access to the 'jq' utility to run - it should be included in /usr/bin or /usr/local/bin of this container!"
  exit 1
fi
 
# Go find our serviceaccount token
KUBE_TOKEN=`cat /var/run/secrets/kubernetes.io/serviceaccount/token`
[[ "$DEBUG" == "true" ]] && echo "Service Account Token is: $KUBE_TOKEN"
 
# Select the ca options for curling the Kubernetes API
[[ "$DEBUG" == "true" ]] && echo "Looking for /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
if [ -e /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]; then
  CAOPTS="--cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  CERT=`cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt`
  [[ "$DEBUG" == "true" ]] && echo "Found /var/run/secrets/kubernetes.io/serviceaccount/ca.crt, using curl with --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  [[ "$DEBUG" == "true" ]] && echo "CA Certificate is $CERT "
else
  [[ "$DEBUG" == "true" ]] && echo "Could not find /var/run/secrets/kubernetes.io/serviceaccount/ca.crt, using curl with -k option"
fi
 
#API
CURL="curl -s -H \"Authorization: bearer $KUBE_TOKEN\" $CAOPTS"
HOSTURL="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
 
# Check that the CLUSTER variable has been set
if [[ "$CLUSTER" == "" ]]; then
  echo "Error: You MUST set the environment variable CLUSTER with the address of your gluster cluster!"
  sleep 60
  exit 1
else
  echo "gluster cluster: $CLUSTER"
fi
# Allow people to use pipe to separate the gluster hosts with a ;
# because using a ',' in openshift template parameters is hard.
CLUSTER=${CLUSTER/;/,}
 
# INTERVAL defaults to 5 minutes
[[ "$INTERVAL" == "" ]] && INTERVAL=300
 
function api_call {
  local method=$1
  local call=$2
  local body=$3
 
  [[ "$DEBUG" == "true" ]] && echo >&2 "api_call method=$method call=$call body=$body"
 
  # set up the appropriate curl command
  if [[ "$body" == "" ]]; then
    local curl_command="$CURL -X $method $opts ${HOSTURL}${call}"
  else
    local curl_command="$CURL -H \"Content-Type: application/json\" -X $method -d '${body}' ${HOSTURL}${call}"
  fi
  [[ "$DEBUG" == "true" ]] && echo >&2 "command: $curl_command"
 
  # In READONLY mode only allow GET's to run against the API
  if [[ "$READONLY" == "true" && "$method" != "GET" ]]; then
    echo >&2 "READONLY MODE - would have performed this API call: $method $call"
    return 0
  fi
 
  # Execute the API call via curl and check for curl errors.
  local command_result=`eval $curl_command`
  if [ "$?" -ne "0" ]; then
    echo >&2 "ERROR! Curl command failed to run properly"
    echo >&2 "$command_result"
    return 1
  fi
  [[ "$DEBUG" == "true" ]] && echo >&2 "result: $command_result"
 
  # Look at response and check for Kubernetes errors.
  local api_result=`echo "$command_result" | $JQ '.status'`
  [[ "$DEBUG" == "true" ]] && echo >&2 "api_result: $api_result"
  if [[ "$api_result" == "Failure" ]]; then
    echo >&2 "ERROR API CALL FAILED!:-"
    echo >&2 "$command_result"
    return 1
  else
    echo "$command_result"
    return 0
  fi
}
 
# start the loop
while true
do
 
  # Get a list of physical volumes and their status
  [[ "$DEBUG" == "true" ]] && echo "Getting a list of persistentvolumes..."
  vol_list=`api_call GET /api/v1/persistentvolumes`
  if [ "$?" -eq "0" ]; then
    [[ "$DEBUG" == "true" ]] && echo "result of api call: $vol_list"
 
    # interate over the persistent volumes a volume at a time
    num_vols=`echo $vol_list | $JQ '.items | length'`
    echo "$num_vols persistent volumes found"
    for i in $(seq 0 $((num_vols - 1))); do
 
      # Only process volumes which are in failed phase, are glusterfs and have a message of "no volume plugin matched"
      # so that we only try to recycle volumes which have been given back to the cluster and don't have a valid
      # recycler plugin.
      [[ "$DEBUG" == "true" ]] && echo "result index $i"
      volume_with_status=`echo $vol_list | $JQ '.items['$i']'`
      [[ "$DEBUG" == "true" ]] && echo "Examining the following volume:-"
      [[ "$DEBUG" == "true" ]] && echo "$volume_with_status"
      vol_name=`echo $volume_with_status | $JQ '.metadata.name'`
      is_failed=`echo $volume_with_status | $JQ '.status.phase'`
      if [[ "$is_failed" == "Failed" ]]; then
        [[ "$DEBUG" == "true" ]] && echo "Volume $vol_name is in Failed state!"
        is_gluster=`echo $volume_with_status | $JQ '.glusterfs'`
        if [[ "$is_gluster" != "" ]]; then
          [[ "$DEBUG" == "true" ]] && echo "Volume $vol_name is a glusterfs volume and is in a failed state!"
          message=`echo $volume_with_status | $JQ '.status.message'`
          if [[ "$message" == "no volume plugin matched" ]]; then
            echo "*****"
            echo "Attempting to re-cycle volume $vol_name"
            echo "*****"
 
            # mount the volume
            [[ "$DEBUG" == "true" ]] && echo "Mounting Volume: mount.glusterfs ${CLUSTER}:${vol_name} /mnt"
            mount.glusterfs ${CLUSTER}:${vol_name} /mnt
            if [[ "$?" != "0" ]]; then
              echo "ERROR! Unable to mount the volume."
              continue
            else
              echo "Successfully mounted volume ${vol_name} to /mnt"
              [[ "$DEBUG" == "true" ]] && echo "Volume contains the following files:-"
              [[ "$DEBUG" == "true" ]] && find /mnt
            fi
 
            # delete all the files with -mindepth 1 so we don't try and remove /mnt
            [[ "$DEBUG" == "true" ]] && echo "Deleting all files and dirs: find /mnt -mindepth 1 -not -path \"/mnt/.trashcan*\" -delete"
            find /mnt -mindepth 1 -not -path "/mnt/.trashcan*" -delete
            if [[ "$?" != "0" ]]; then
              echo "ERROR! We could not remove all of the files in this volume!!"
            else
                echo "Recreating volume $vol_name in kubernetes..."
                #vol_def=`echo $volume_with_status | $JQ '- .status .metadata.selflink, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp ]'`
                vol_def=`echo $volume_with_status | $JQ 'del(.status) | del(.spec.claimRef) | del(.metadata.selfLink) | del(.metadata.uid) | del(.metadata.resourceVersion) | del(.metadata.creationTimestamp)'`
                [[ "$DEBUG" == "true" ]] && echo "Sanitized volume config definition is:-"
                [[ "$DEBUG" == "true" ]] && echo "$vol_def"
                [[ "$DEBUG" == "true" ]] && echo "Deleting $vol_name"
                delete_result=`api_call DELETE /api/v1/persistentvolumes/${vol_name}`
                if [ "$?" -eq "0" ]; then
                  [[ "$DEBUG" == "true" ]] && echo "result of api call: $delete_result"
                  # re-create the object
                  add_result=`api_call POST /api/v1/persistentvolumes "$vol_def"`
                  if [ "$?" -eq "0" ]; then
                    [[ "$DEBUG" == "true" ]] && echo "result of api call: $add_result"
                    echo "Successfully re-cycled volume ${vol_name}"
                  else
                    echo "ERROR! I couldn't re-create volume ${vol_name} via Kubernetes API.  The response was:-"
                    echo "$add_result"
                  fi
                else
                  echo "ERROR! I couldn't delete volume ${vol_name} via Kubernetes API.  The response was:-"
                  echo "$delete_result"
                fi
            fi
 
            [[ "$DEBUG" == "true" ]] && echo "unmounting $vol_name"
            umount /mnt
          fi
        fi
      fi
    done
    echo "Finished recycle run"
 
  else
    echo "ERROR! Could not get list of volumes from the API!"
    sleep 60
    exit 1
  fi
 
  # wait for next run through
  sleep $INTERVAL
 
done
exit 0
