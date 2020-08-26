#!/bin/bash

set -e

SCRIPT_DIR=$(dirname $(readlink -f $0))
VARS_SRC="$SCRIPT_DIR/vars.sh"

source "$VARS_SRC"

# This script is pointless if no NTP servers are defined.
# This entire procedure is only required if custom NTP servers are necessary.
# Just unset the NTP_SERVERS variable in vars.sh and this script will be
# skipped altogether.
#
# This script is essentially an automation of the solution at
# https://access.redhat.com/solutions/4906341
#
# Temporary and backup files generated by this script are left behind. They're
# overwritten on each run and are useful for debugging this script.

if [[ ${#NTP_SERVERS[@]} -lt 1 ]]
then
  echo "## No NTP_SERVERS specified. Exiting."
  exit 255
fi

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

diff -u "bootstrap.ign.bak.json" "bootstrap.ign"
echo

for i in master worker
do
  echo "# Updating ${i}.ign."
  jq -M --slurpfile chrony "$CHRONY_CONF_IGN_FILE" \
    '.storage.files |= . + $chrony' \
    "${i}.ign.bak" > "${i}.ign"

  diff -u "${i}.ign.bak.json" "${i}.ign"
  echo
done

popd
echo
echo "## You can now deploy the cluster."
echo
