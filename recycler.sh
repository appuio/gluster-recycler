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
# Retrieves a list of persistentvolumes from kubernetes and for each glusterfs volume in a failed state:
#  mount volume
#  remove all contents
#  delete and re-add the volume

#####################################################################################
# Inputs are ENVIRONMENT VARIABLES
#
# CLUSTER - the address string of the gluster cluster, e.g.
# INTERVAL - the pause between recyle runs in seconds (default 5 minutes)
# DELAY - number of seconds to delay recycling after pv has first been seen in failed state
# DEBUG - set to 'true' to enable detailed logging.

JQ="jq -c -M -r"
ANNOTATION_FAILED_AT=appuio.ch/failed-at

DELAY="${DELAY:-0}"
if [[ ! $DELAY =~ [0-9]+ ]]; then
  DELAY="0"
  echo "DELAY is not a number, ignoring!" >&2
fi

is_debug() {
  [[ "$DEBUG" == true ]]
}

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

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Go find our serviceaccount token
KUBE_TOKEN=`cat /var/run/secrets/kubernetes.io/serviceaccount/token`
is_debug && echo "Service Account Token is: $KUBE_TOKEN"

# Select the ca options for curling the Kubernetes API
is_debug && echo "Looking for /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
if [ -e /var/run/secrets/kubernetes.io/serviceaccount/ca.crt ]; then
  CAOPTS=( --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt )
  CERT=`cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt`
  is_debug && echo "Found /var/run/secrets/kubernetes.io/serviceaccount/ca.crt, using curl with --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  is_debug && echo "CA Certificate is $CERT "
else
  CAOPTS=( -k )
  is_debug && echo "Could not find /var/run/secrets/kubernetes.io/serviceaccount/ca.crt, using curl with -k option"
fi

#API
CURL=( curl -s -H "Authorization: bearer $KUBE_TOKEN" "${CAOPTS[@]}" )
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

echo "checking for failed volumes every ${INTERVAL} seconds"
echo "delaying recycling of failed volumes for ${DELAY} seconds"
echo

function api_call {
  local method=$1
  local call=$2
  local body=$3
  local type="${4:-application/json}"

  is_debug && echo >&2 "api_call method=$method call=$call body=$body"

  local curl_command=( "${CURL[@]}" -X "$method" )

  # set up the appropriate curl command
  if [[ -n "$body" ]]; then
    curl_command+=( -H "Content-Type: $type" -d "$body" )
  fi
  curl_command+=( "${HOSTURL}${call}" )
  is_debug && echo >&2 command: "${curl_command[@]}"

  # In READONLY mode only allow GET's to run against the API
  if [[ "$READONLY" == "true" && "$method" != "GET" ]]; then
    echo >&2 "READONLY MODE - would have performed this API call: $method $call"
    return 0
  fi

  # Execute the API call via curl and check for curl errors.
  if command_result=$( "${curl_command[@]}" ); then
    :
  else
    echo >&2 "ERROR! Curl command failed to run properly"
    echo >&2 "$command_result"
    return 1
  fi
  is_debug && echo >&2 "result: $command_result"

  # Look at response and check for Kubernetes errors.
  local api_result=`echo "$command_result" | $JQ '.status'`
  is_debug && echo >&2 "api_result: $api_result"
  if [[ "$api_result" == "Failure" ]]; then
    echo >&2 "ERROR API CALL FAILED!:-"
    echo >&2 "$command_result"
    return 1
  else
    echo "$command_result"
    return 0
  fi
}

clear_volume() {
  local path="$1"

  # Normalize path
  if ! path=$(readlink -f -- "$path"); then
    return 1
  fi

  if is_debug; then
    echo "Volume contains the following files:"
    find "$path" | sort
  fi

  # delete all the files with -mindepth 1 so we don't try and remove the mount directory
  find "$path" -mindepth 1 -not -path "${path}/.trashcan*" -delete
  if [[ "$?" != 0 ]]; then
    echo "ERROR: We could not remove all of the files in this volume!"
    return 1
  fi

  return 0
}

recreate_volume() {
  local volfile="$1"
  local vol_name
  local vol_def="${tmpdir}/recreate.json"

  vol_name=$(jq -r '.metadata.name' < "$volfile")

  echo "Recreating volume ${vol_name}"

  jq -r '
    del(.status) |
    del(.spec.claimRef) |
    del(.metadata.selfLink) |
    del(.metadata.uid) |
    del(.metadata.resourceVersion) |
    del(.metadata.creationTimestamp) |
    del(.metadata.annotations)
    ' \
    < "$volfile" \
    > "$vol_def"

  if is_debug; then
    echo "Sanitized volume config definition is:"
    cat "$vol_def"
    echo "Deleting ${vol_name}"
  fi

  if ! delete_result=$(api_call DELETE "/api/v1/persistentvolumes/${vol_name}"); then
    echo "ERROR: Couldn't delete volume ${vol_name} via Kubernetes API. The response was:"
    echo "$delete_result"
    return
  fi

  if is_debug; then
    echo "result of api call: $delete_result"
  fi

  # re-create the object
  if add_result=$(api_call POST /api/v1/persistentvolumes "@${vol_def}"); then
    if is_debug; then
      echo "result of api call: $add_result"
    fi
    echo "Successfully re-cycled volume ${vol_name}"
  else
    echo "ERROR: Couldn't re-create volume ${vol_name} via Kubernetes API.  The response was:"
    echo "$add_result"
  fi

  return
}

recycle_volume() {
  local volfile="$1"
  local vol_name
  local vol_path
  local vol_isgluster
  local vol_message
  local vol_failed_at
  local bits

  if is_debug; then
    echo "Examining the following volume:"
    jq -C . < "$volfile"
  fi

  bits=$($JQ --arg annotname "$ANNOTATION_FAILED_AT" '@sh "
    vol_name=\(.metadata.name)
    vol_path=\(.spec.glusterfs.path)
    vol_phase=\(.status.phase)
    vol_isgluster=\(if .spec.glusterfs then "yes" else "" end)
    vol_message=\(.status.message)
    vol_failed_at=\(.metadata.annotations[$annotname] // "")
    "' < "$volfile")

  if is_debug; then
    echo "Variables: ${bits}"
  fi

  eval "$bits"

  local mountdir="/mnt/${vol_name}"

  if mountpoint -q "$mountdir"; then
    echo "Volume \"${vol_name}\" is still mounted"
    umount "$mountdir"
  fi

  # Only process volumes which are in failed phase, are glusterfs and have a message of "no volume plugin matched"
  # so that we only try to recycle volumes which have been given back to the cluster and don't have a valid
  # recycler plugin.

  if [[ "$vol_phase" != Failed ]]; then
    return
  fi

  if is_debug; then
    echo "Volume $vol_name is in Failed state!"
  fi

  if [[ -z "$vol_isgluster" ]]; then
    # Not a Gluster volume
    return
  fi

  if is_debug; then
    echo "Volume ${vol_name} is a glusterfs volume and is in a failed state"
  fi

  case "$vol_message" in
    'no volume plugin matched' | \
    'No recycler plugin found for the volume!')
      ;;
    *)
      return
      ;;
  esac

  if [[ "$DELAY" != 0 ]]; then
    if [[ -z "$vol_failed_at" ]]; then
      local failed_at=$(date -Is)
      local patch=$(jq -r --null-input \
        --arg annotname "$ANNOTATION_FAILED_AT" \
        --arg failed_at "$failed_at" '{
        "metadata": {
          "annotations": {
            ($annotname): $failed_at
          }
        }
      }')
      local patch_result

      echo "Annotating ${vol_name} as failed at ${failed_at}"

      patch_result=$(api_call PATCH "/api/v1/persistentvolumes/${vol_name}" "$patch" application/strategic-merge-patch+json)
      if [[ "$?" != 0 ]]; then
        echo "Couldn't annotate ${vol_name} with failed timestamp. The response was:"
        echo "$patch_result"
      fi

      return
    fi

    local now_minus_delay=$(date -Is "-d-${DELAY}sec")

    if [[ "$now_minus_delay" < "$vol_failed_at" ]]; then
      # Not enough time has passed
      return
    fi
  fi

  echo "Recycling volume ${vol_name}"

  # mount the volume
  if is_debug; then
    echo "Mounting volume: mount.glusterfs \"${CLUSTER}:${vol_path}\" \"${mountdir}\""
  fi

  if [[ ! -d "$mountdir" ]]; then
    mkdir "$mountdir"
  fi

  mount.glusterfs "${CLUSTER}:${vol_path}" "$mountdir"
  if [[ "$?" != "0" ]]; then
    echo "ERROR: Unable to mount the volume"
    return
  fi

  echo "Successfully mounted volume ${vol_name} to ${mountdir}"

  if clear_volume "$mountdir"; then
    recreate_volume "$volfile"
  fi

  if is_debug; then
    echo "Unmounting $vol_name"
  fi
  umount "$mountdir"
}

# start the loop
while true
do

  # Get a list of physical volumes and their status
  is_debug && echo "Getting a list of persistentvolumes..."
  vol_list=`api_call GET /api/v1/persistentvolumes`
  if [ "$?" -eq "0" ]; then
    is_debug && echo "result of api call: $vol_list"

    echo "$vol_list" | \
      jq -r '.items | map(select(.status.phase == "Failed"))' \
      > "${tmpdir}/failed.json"

    num_vols=$(jq -r length < "${tmpdir}/failed.json")

    echo "$(date -Is): ${num_vols} failed volumes found"

    # interate over the persistent volumes a volume at a time
    for i in $(seq 0 $((num_vols - 1))); do
      jq -r --argjson idx "$i" '.[$idx]' \
        < "${tmpdir}/failed.json" \
        > "${tmpdir}/volume.json"

      recycle_volume "${tmpdir}/volume.json"
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
