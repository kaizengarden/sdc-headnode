#!/usr/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2014, Joyent, Inc.
#

#
# Upgrade the tools from usb-headnode.git/tools/... to /opt/smartdc/bin
# This requires a local copy of that 'tools/...' dir.
#
# Limitation: for now we are ignoring updates to tools-modules/... and
# tools-man/...
#

if [[ -n "$TRACE" ]]; then
    export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -o xtrace
fi
set -o errexit
set -o pipefail


#---- support stuff

function fatal
{
    echo "$0: fatal error: $*"
    exit 1
}


#---- mainline

[[ $(sysinfo | json "Boot Parameters.headnode") == "true" ]] \
    || fatal "not running on the headnode"
[[ ! -f "./tools.tar.gz" ]] && fatal "there is no './tools.tar.gz' from which to upgrade!"

# Guard on having an 'sdc' zone. If the HN doesn't have one, then the new
# tools will all be broken.
sdc_zone_uuid=$(vmadm lookup -1 state=running tags.smartdc_role=sdc)
if [[ -z ${sdc_zone_uuid} ]]; then
    fatal "this SDC headnode does not have an 'sdc' zone, cannot upgrade" \
      "to the latest tools"
fi

# Ensure the /opt/smartdc/sdc symlink exists, and points to the 'sdc' zone
rm -rf /opt/smartdc/sdc
ln -s /zones/${sdc_zone_uuid}/root/opt/smartdc/sdc /opt/smartdc/sdc

# Upgrade tools from the bundled tools tarball
/usr/bin/tar xzof tools.tar.gz -C /opt/smartdc

# Remove problematic files from old sdc-clients-light versions
EMPTY_FILES="/opt/smartdc/node_modules/sdc-clients/node_modules/semver.js"
for empty_file in $EMPTY_FILES; do
    [[ -f $empty_file ]] && rm $empty_file
done

[[ ! -d "./scripts" ]] && fatal "there is no './scripts' dir from which to upgrade!"


echo 'Mount USB key and upgrade [/mnt]/usbkey/scripts.'


/usbkey/scripts/mount-usb.sh
if [[ ! -d "/mnt/usbkey/scripts" ]]; then
    echo "unable to mount /mnt/usbkey" >&2
    exit 1
fi

cp -Rp /usbkey/scripts pre-upgrade.scripts.$(date +%s)
rm -rf /mnt/usbkey/scripts /usbkey/scripts
cp -Rp scripts /mnt/usbkey/scripts
cp -Rp scripts /usbkey/scripts
cp scripts/joysetup.sh /usbkey/extra/joysetup/
cp scripts/agentsetup.sh /usbkey/extra/joysetup/

if [[ -f /usbkey/tools.tar.gz ]]; then
    cp /usbkey/tools.tar.gz pre-upgrade.tools.$(date +%s).tar.gz
fi
cp tools.tar.gz /usbkey/tools.tar.gz
cp tools.tar.gz /mnt/usbkey/tools.tar.gz

cp default/* /mnt/usbkey/default
cp default/* /usbkey/default

umount /mnt/usbkey

