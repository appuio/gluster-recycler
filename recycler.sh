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
# Retrieves a list of persistentvolumes from kubernetes and for each glusterfs volume in a failed state:
#  mount volume
#  remove all contents
#  delete and re-add the volume

#####################################################################################
# Inputs are ENVIRONMENT VARIABLES
#
# CLUSTER - the address string of the gluster cluster
# DELAY - number of seconds to delay recycling after pv has first been seen in failed state
# DEBUG - set to 'true' to enable detailed logging.

ANNOTATION_FAILED_AT=appuio.ch/failed-at
SECRETS_DIR=/recycler-secrets

DELAY="${DELAY:-0}"
if [[ ! $DELAY =~ [0-9]+ ]]; then
  DELAY="0"
  echo "DELAY is not a number, ignoring!" >&2
fi

is_debug() {
  [[ "$DEBUG" == true ]]
}

if is_debug; then
  set -x
fi

# Check we can find the Kubernetes service
if [[ -z "${KUBERNETES_SERVICE_HOST}" || -z "${KUBERNETES_SERVICE_PORT}" ]]; then
  echo 'Kubernetes API is located via environment variables' \
    'KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT, but at least one' \
    'of them is not set'
  exit 1
fi

# Check that we have access to jq
if ! type -p jq >/dev/null; then
  echo '"jq" utility is required to run"'
  exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Go find our serviceaccount token
KUBE_TOKEN=$(< /var/run/secrets/kubernetes.io/serviceaccount/token)
if is_debug; then
  echo "Service account token: $KUBE_TOKEN"
fi

# Select the ca options for curling the Kubernetes API
k8s_cacert=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
if [[ -e "$k8s_cacert" ]]; then
  CAOPTS=( --cacert "$k8s_cacert" )
  if is_debug; then
    {
      echo "Using ${k8s_cacert} as CA file:"
      cat $k8s_cacert
    } >&2
  fi
else
  if is_debug; then
    echo "Could not find ${k8s_cacert}, disabling certificate validation" >&2
  fi
  CAOPTS=( -k )
fi

#API
CURL=( curl -s -H "Authorization: bearer $KUBE_TOKEN" "${CAOPTS[@]}" --max-time 60 )
HOSTURL="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"

# Permit separating Gluster hosts with both ";" and "," (Gluster FUSE requires
# comma)
CLUSTER=${CLUSTER/;/,}

if [[ -n "$CLUSTER" ]]; then
  echo "Gluster cluster: $CLUSTER"
elif [[ -n "$GLUSTER_OBJECT_NAMESPACE" ]]; then
  echo "Gluster object namespace: $GLUSTER_OBJECT_NAMESPACE"
else
  echo "Environment variable \"CLUSTER\" or \"GLUSTER_OBJECT_NAMESPACE\" must be set"
  exit 1
fi

if [[ -s "${SECRETS_DIR}/tls.key" &&
      -s "${SECRETS_DIR}/tls.crt" &&
      -s "${SECRETS_DIR}/tls.ca" ]]; then
  echo "TLS support enabled"
  cp -v "${SECRETS_DIR}/tls.key" /etc/ssl/glusterfs.key
  cp -v "${SECRETS_DIR}/tls.crt" /etc/ssl/glusterfs.pem
  cp -v "${SECRETS_DIR}/tls.ca" /etc/ssl/glusterfs.ca
  if [[ -s "${SECRETS_DIR}/tls.dhparam" ]]; then
    cp -v "${SECRETS_DIR}/tls.dhparam" /etc/ssl/dhparam.pem
  fi
  touch /var/lib/glusterd/secure-access
else
  rm -f /var/lib/glusterd/secure-access
fi

echo "Delaying recycling of failed volumes for ${DELAY} seconds"

function api_call {
  local method=$1
  local call=$2
  local body=$3
  local type="${4:-application/json}"

  if is_debug; then
    echo "api_call method=$method call=$call body=$body" >&2
  fi

  local curl_command=( "${CURL[@]}" -X "$method" )

  # set up the appropriate curl command
  if [[ -n "$body" ]]; then
    curl_command+=( -H "Content-Type: $type" -d "$body" )
  fi
  curl_command+=( "${HOSTURL}${call}" )

  if is_debug; then
    echo command: "${curl_command[@]}" >&2
  fi

  # In READONLY mode only allow GET's to run against the API
  if [[ "$READONLY" == "true" && "$method" != "GET" ]]; then
    echo "READONLY MODE: Would perform API call $method $call" >&2
    return 0
  fi

  # Execute the API call via curl and check for curl errors.
  if ! command_result=$( "${curl_command[@]}" ); then
    echo "cURL failed: ${command_result}" >&2
    return 1
  fi

  if is_debug; then
    echo "result: $command_result" >&2
  fi

  # Look at response and check for Kubernetes errors.
  local api_result=$(echo "$command_result" | jq -r '.status')
  if is_debug; then
    echo "api_result: $api_result" >&2
  fi
  if [[ "$api_result" == "Failure" ]]; then
    echo "API request ${method} ${call} failed: ${command_result}" >&2
    return 1
  fi

  echo "$command_result"

  return 0
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
  if ! find "$path" -mindepth 1 -not -path "${path}/.trashcan/*" -delete; then
    echo Removing volume content failed
    return 1
  fi

  # try to remove the trashcan but ignore errors if it fails
  rm -rf "${path}/.trashcan" || :

  # reset owner to root
  if ! chown -R -c root:root "$path"; then
    echo Resetting volume owner/group failed
    return 1
  fi

  # reset permissions
  if ! chmod -R -c 2775 "$path"; then
    echo Resetting permissions failed
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
    echo "Sanitized volume config definition:"
    cat "$vol_def"
    echo "Deleting ${vol_name}"
  fi

  if ! delete_result=$(api_call DELETE "/api/v1/persistentvolumes/${vol_name}"); then
    echo "Deleting volume ${vol_name} failed" >&2
    return 1
  fi

  if is_debug; then
    echo "result of api call: $delete_result"
  fi

  # re-create the object
  if ! add_result=$(api_call POST /api/v1/persistentvolumes "@${vol_def}"); then
    echo "Re-creating volume ${vol_name} failed"
    return 1
  fi

  echo "Successfully re-cycled volume ${vol_name}"
  return 0
}

recycle_volume() {
  local volfile="$1"
  local vol_name
  local vol_path
  local vol_endpoints
  local vol_phase
  local vol_isgluster
  local vol_message
  local vol_failed_at
  local bits
  local gluster_endpoints

  if is_debug; then
    echo "Examining the following volume:"
    jq -C . < "$volfile"
  fi

  bits=$(jq -r --arg annotname "$ANNOTATION_FAILED_AT" '@sh "
    vol_name=\(.metadata.name)
    vol_path=\(.spec.glusterfs.path // "")
    vol_endpoints=\(.spec.glusterfs.endpoints // "")
    vol_phase=\(.status.phase // "")
    vol_isgluster=\(if .spec.glusterfs then "yes" else "" end)
    vol_message=\(.status.message // "")
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

  if [[ -z "$vol_isgluster" || -z "$vol_endpoints" ]]; then
    # Not an acceptable Gluster volume
    return 0
  fi

  if [[ "$vol_phase" == Failed ]]; then
    case "$vol_message" in
      'no volume plugin matched' | \
      'No recycler plugin found for the volume!')
        ;;
      *)
        return 0
        ;;
    esac
  elif ! [[ "$vol_phase" == Released && -z "$vol_message" ]]; then
    return 0
  fi

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

      echo "Annotating ${vol_name} as failed at ${failed_at}"

      if ! api_call PATCH "/api/v1/persistentvolumes/${vol_name}" "$patch" application/strategic-merge-patch+json; then
        echo "Annotating ${vol_name} with failure timestamp failed"
        return 1
      fi

      return 0
    fi

    local now_minus_delay=$(date -Is "-d-${DELAY}sec")

    if [[ "$now_minus_delay" < "$vol_failed_at" ]]; then
      # Not enough time has passed
      return 0
    fi
  fi

  echo "Recycling volume ${vol_name}"

  if [[ -n "$CLUSTER" ]]; then
    gluster_endpoints="$CLUSTER"
  elif [[ -n "$GLUSTER_OBJECT_NAMESPACE" ]]; then
    local gluster_endpoints_json

    if ! gluster_endpoints_json=$(
      api_call GET "/api/v1/namespaces/${GLUSTER_OBJECT_NAMESPACE}/endpoints/${vol_endpoints}"
      )
    then
      echo "Retrieving endpoint object \"${vol_endpoints}\" from namespace \"${GLUSTER_OBJECT_NAMESPACE}\" failed" >&2
      return 1
    fi

    if ! gluster_endpoints=$(
      echo "$gluster_endpoints_json" | \
      jq -r '[.subsets[].addresses[].ip] | select(.) | sort | join(",")'
      )
    then
      echo 'Failed to extract endpoints' >&2
      return 1
    fi
  else
    echo 'Storage servers not specified' >&2
    return 1
  fi

  if [[ ! -d "$mountdir" ]]; then
    mkdir "$mountdir"
  fi

  local logfile="${tmpdir}/mount.log"

  # Clear logfile
  :>"$logfile"

  local mountcmd

  mountcmd=(
    mount.glusterfs "${gluster_endpoints}:${vol_path}" "$mountdir"
      -o log-level=INFO,log-file="${logfile}"
    )

  if is_debug; then
    echo 'Mount command:' "${mountcmd[@]}"
  fi

  if ! "${mountcmd[@]}"; then
    echo "Unable to mount volume ${vol_name}"
    cat "$logfile"
    return 1
  fi

  echo "Successfully mounted volume ${vol_name} to ${mountdir}"

  local failed=
  if ! clear_volume "$mountdir"; then
    failed=yes
    cat "$logfile"
  fi

  if is_debug; then
    echo "Unmounting $vol_name"
  fi
  if ! umount "$mountdir"; then
    failed=yes
  fi

  if [[ -z "$failed" ]] && ! recreate_volume "$volfile"; then
    failed=yes
  fi

  [[ -z "$failed" ]]
}

# Get a list of physical volumes and their status
if ! vol_list=$(api_call GET /api/v1/persistentvolumes); then
  echo 'Retrieving list of volumes failed'
  exit 1
fi

echo "$vol_list" | \
  jq -r '.items | map(select(.status.phase == "Failed" or .status.phase == "Released"))' \
  > "${tmpdir}/failed.json"

num_vols=$(jq -r length < "${tmpdir}/failed.json")

echo "${num_vols} failed volumes found"

exit_status=0

# interate over the persistent volumes a volume at a time
for i in $(seq 0 $((num_vols - 1))); do
  jq -r --argjson idx "$i" '.[$idx]' \
    < "${tmpdir}/failed.json" \
    > "${tmpdir}/volume.json"

  if ! recycle_volume "${tmpdir}/volume.json"; then
    exit_status=1
  fi
done
echo 'Finished recycle run'

exit "$exit_status"
