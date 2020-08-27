#!/bin/bash

set -e

SCRIPT_DIR=$(dirname $(readlink -f $0))
VARS_SRC="$SCRIPT_DIR/vars.sh"

source "$VARS_SRC"

# This script installs OCP on OCS. It expects that you've already setup the DNS
# configuration either via hosts or dnsmasq (or equivalent). If the NTP_SERVERS
# array is defined with at least one value in vars.sh, it prepares the ignition
# files and adds the corresponding chrony.conf file to it before installing
# OCP.
#
# Temporary and backup files generated by this script are left behind. They're
# overwritten on each run and are useful for debugging this script.

if [[ ${#NTP_SERVERS[@]} -lt 1 ]]
then
  echo "## No NTP_SERVERS specified. Skipping the ignition stuff."
else
  # This entire procedure is only required if custom NTP servers are necessary.
  # Just unset the NTP_SERVERS variable in vars.sh and this script will be
  # skipped altogether.
  #
  # This part of the script is essentially an automation of the solution at
  # https://access.redhat.com/solutions/4906341
  echo "## Generating chrony.conf and its corresponding ignition json."

  CHRONY_CONF_FILE="$SCRIPT_DIR/chrony.conf"

  (
    for ntp_server in "${NTP_SERVERS[@]}"
    do
      echo "pool $ntp_server iburst"
    done
  ) > "$CHRONY_CONF_FILE"

  # Generate chrony.conf
  cat >> "$CHRONY_CONF_FILE" <<_CHRONY_
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
_CHRONY_

  # Generate json object with base64 string for the chrony configuration
  CHRONY_CONF_STR="data:text/plain;charset=utf-8;base64,$(base64 -w0 <$CHRONY_CONF_FILE)"

  CHRONY_CONF_IGN_FILE="$SCRIPT_DIR/chrony.conf_ign.json"
  cat > "$CHRONY_CONF_IGN_FILE" <<_JSON_
{
  "filesystem": "root",
  "path": "/etc/chrony.conf",
  "user": {
    "name": "root"
  },
  "append": false,
  "contents": {
    "source": "$CHRONY_CONF_STR",
    "verification": {}
  },
  "mode": 420
}
_JSON_

  echo
  echo "# chrony configuration generated for insertion into ignition files:"
  echo
  jq -M .contents.source "$CHRONY_CONF_IGN_FILE" | sed -r 's/"//g;s/^.+base64,//' | base64 -d

  echo
  echo "## Preparing cluster directory and copying configuration."
  echo

  mkdir -pv "$CLUSTER_DIR"

  cp -v "$INSTALL_CONFIG" "$CLUSTER_DIR/install-config.yaml"

  pushd "$CLUSTER_DIR"

  echo
  echo "## Creating ignition configuration files and backing them up."
  echo
  openshift-install create ignition-configs

  for i in {bootstrap,master,worker}.ign
  do
    bkup_file="${i}.bak"
    mv -v "$i" "$bkup_file"
    jq -M . "$bkup_file" > "${i}.bak.json"
  done

  echo "# Updating bootstrap.ign."
  # This next bit of bootstrap specific array slicing is necessary only to insert
  # the chrony configuration immediately after motd. Don't know why; but that's
  # how the solution says it is done; so whatever.
  chrony_index=$(jq -M '.storage.files | map(.path == "/etc/motd") | index(true)' bootstrap.ign.bak)
  let chrony_index++

  jq -M --slurpfile chrony "$CHRONY_CONF_IGN_FILE" \
    ".storage.files[0:$chrony_index] + \$chrony + .storage.files[$chrony_index:]" \
    "bootstrap.ign.bak" > "bootstrap_files_array.json"

  jq -M --slurpfile files "bootstrap_files_array.json" \
    'del(.storage.files) | .storage |= . + {files:($files[])}' \
    "bootstrap.ign.bak" > "bootstrap.ign"

  diff -u "bootstrap.ign.bak.json" "bootstrap.ign" || true
  echo

  for i in master worker
  do
    echo "# Updating ${i}.ign."
    jq -M --slurpfile chrony "$CHRONY_CONF_IGN_FILE" \
      '.storage.files |= . + $chrony' \
      "${i}.ign.bak" > "${i}.ign"

    diff -u "${i}.ign.bak.json" "${i}.ign" || true
    echo
  done
fi

echo
echo "## Installing OCP."
echo

openshift-install create cluster

echo
echo "## Setting up the ingress floating IP: $FLOATING_IP"
echo

if ! [[ -f $TF_VARS_FILE ]]
then
  echo "Unable to read terraform vars file: $TF_VARS_FILE"
  exit 1
fi

export CLUSTER_ID=$(jq -M '.cluster_id' "$TF_VARS_FILE" | sed 's/"//g')
echo "# Cluster ID: $CLUSTER_ID"
INGRESS_PORT="${CLUSTER_ID}-ingress-port"
echo "# Ingress Port: $INGRESS_PORT"
echo "# Floating IP: $FLOATING_IP"
openstack floating ip set --port "$INGRESS_PORT" "$FLOATING_IP"
echo "# Floating IP set."

ping_console() {
  echo -n "# Checking if console is reachable on the floating IP.."
  ping -c 1 console-openshift-console.apps.ocs.mkarnik.com &> /dev/null
  PING_SUCCESS=$?
  if ! [[ $PING_SUCCESS == 0 ]]
  then
    echo " retrying."
  fi

  return $PING_SUCCESS
}

while ! ping_console; do true; done
echo " done!"
echo

popd

if ! [[ $UPDATE_PULL_SECRET == true ]]
then
  echo
  echo "## UPDATE_PULL_SECRET is not 'true'. Exiting."
  exit 0
fi

echo
echo "## Pull secret update."
echo

export KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig"
echo "# Using KUBCONFIG=$KUBCONFIG"

oc get nodes

PULL_SECRET_OUTPUT="${CLUSTER_DIR}/pull-secret_${CLUSTER_ID}.json"
echo "# Cluster ID: $CLUSTER_ID"
echo "# Pull secret output file: $PULL_SECRET_OUTPUT"

if [[ -s $PULL_SECRET_OUTPUT && $(jq 'has("auths")' <"$PULL_SECRET_OUTPUT") == true ]]
then
  echo "'${PULL_SECRET_OUTPUT}' exists and contains the 'auths' object."
  echo "Not updating the pull secret."
else
  echo "'${PULL_SECRET_OUTPUT}' either doesn't exist or does not contain the 'auths' object."
  if [[ $(jq 'has("auths")' <$AUTHS_FILE) == true ]]
  then
    echo "'$AUTHS_FILE' contains the 'auths' object."
    echo "Fetching existing pull secrets into '$SECRETS_FILE'."
    oc get -n openshift-config secret/pull-secret -ojson | jq -r '.data.".dockerconfigjson"' | base64 -d | jq . -M > "$SECRETS_FILE"
    echo "Merging '${AUTHS_FILE}' into '${SECRETS_FILE}'."
    jq -s '.[0] * .[1]' "$SECRETS_FILE" "$AUTHS_FILE" -M > "$PULL_SECRET_OUTPUT"
    jq . "$PULL_SECRET_OUTPUT"
    echo "Updating pull-secret on the cluster."
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$PULL_SECRET_OUTPUT"
    echo "Done."
    echo
  fi
fi