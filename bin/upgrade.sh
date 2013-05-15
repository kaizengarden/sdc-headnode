#!/bin/bash
#
# Copyright (c) 2013, Joyent, Inc., All rights reserved.
#
# SUMMARY
#
# This upgrade script is delivered inside the upgrade image, so this script
# is from the latest build, but the system will be running an earlier release.
# The perform-upgrade.sh script from the earlier release unpacks the upgrade
# image (which contains this script) into a temporary directory, then runs
# this script.  Thus, the system will be running the old release while this
# script executes and we cannot depend on any new system behavior from the
# current release we're upgrading to.
#

unset LD_LIBRARY_PATH
# /image/usr/sbin is here so we pickup vmadm on 6.5
PATH=/usr/bin:/usr/sbin:/image/usr/sbin:/opt/smartdc/bin:/smartdc/bin
export PATH

BASH_XTRACEFD=4
export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o xtrace

ROOT=$(pwd)
export SDC_UPGRADE_DIR=/var/upgrade_in_progress

# XXX fix this for oldest supported version
# We use the 6.5.4 USB key image build date to check the minimum
# upgradeable version.
VERS_6_5_4=20120523

ZONES6X="adminui assets billapi ca capi cloudapi dhcpd mapi portal rabbitmq riak"

declare -A ADMIN_IP=()

mounted_usb="false"
usbmnt="/mnt/$(svcprop -p 'joyentfs/usb_mountpoint' \
    svc:/system/filesystem/smartdc:default)"
usbcpy="$(svcprop -p 'joyentfs/usb_copy_path' \
    svc:/system/filesystem/smartdc:default)"

. /lib/sdc/config.sh
load_sdc_sysinfo
load_sdc_config

function cleanup
{
    if [[ ${mounted_usb} == "true" ]]; then
        umount ${usbmnt}
        mounted_usb="false"
    fi

message_term="
ERROR: The upgrade process terminated prematurely.  You can review the upgrade
logs in /var/upgrade_failed to determine how to correct the failure.
The system must now be rebooted to restart all services.\n\n"

    printf "$message_term"

    cd /
    cp -p tmp/*log* $SDC_UPGRADE_DIR
    rm -rf /var/upgrade_failed
    [ -d $SDC_UPGRADE_DIR ] && mv $SDC_UPGRADE_DIR /var/upgrade_failed
    exit 1
}

function recover
{
    if [[ ${mounted_usb} == "true" ]]; then
        umount ${usbmnt}
        mounted_usb="false"
    fi

message_term="
ERROR: The upgrade process encountered an error and is rolling back to the
previous configuration. The rollback will take a couple of minutes and then the
system will reboot to restart all services. After the system reboots, you can
review the upgrade logs in /var/upgrade_failed to determine how to correct
the failure. Until the system reboots, don't do anything.\n\n"

    printf "$message_term"
    cd /

    trap EXIT

    # Use the local copy of rollback since it didn't exist on the 6.5.x usbkey.
    # sdc-rollback handles the /var/upgrade_in_progress file cleanup.
    # Overlay this process with sdc-rollback so that perform-upgrade doesn't
    # think we're done yet.
    . $ROOT/sdc-rollback -F
}

function mount_usbkey
{
    if [[ -z $(mount | grep ^${usbmnt}) ]]; then
        ${usbcpy}/scripts/mount-usb.sh
        mounted_usb="true"
    fi
}

function umount_usbkey
{
	umount /mnt/usbkey
        mounted_usb="false"
}

function fatal
{
    msg=$1

    echo "ERROR: ${msg}" >/dev/stderr

    if [ $CHECK_ONLY -eq 1 ]; then
        FATAL_CNT=$(($FATAL_CNT + 1))
        return
    fi
    exit 1
}

function fatal_rb
{
    msg=$1

    echo "ERROR: ${msg}" >/dev/stderr
    recover
}

function upgrade_pools
{
    #
    # All ZFS pools should have atime=off.  If an operator wants to enable atime
    # on a particular dataset, this setting won't affect that setting, since any
    # datasets with a modified atime property will no longer inherit that
    # setting from the pool's setting.
    #
    local pool
    for pool in $(zpool list -H -o name); do
         zfs set atime=off ${pool} || \
              fatal "failed to set atime=off on pool ${pool}"
    done

    #
    # When this compute node was first setup, it may have had an incorrect dump
    # device size.  Let's fix that.  The dump device should be half the size of
    # available physical memory.
    #
    local system_pool=$(svcprop -p config/zpool smartdc/init)
    local dumpsize=$(zfs get -Hp -o value volsize ${system_pool}/dump)
    if [[ $dumpsize -eq 4294967296 ]]; then
        local newsize_in_MiB=$(( ${SYSINFO_MiB_of_Memory} / 2 ))
        zfs set volsize=${newsize_in_MiB}m ${system_pool}/dump
    fi
}

function upgrade_zfs_datasets
{
    #
    # Certain template datasets were created with ZFS on-disk version 1.  Find
    # those datasets and upgrade them to the latest version.
    #
    zfs upgrade -a
}

function check_capi
{
    CAPI_FOUND=0
    [[ "$CONFIG_capi_is_local" == "true" ]] && CAPI_FOUND=1
}

function trim_db
{
    zstate=`zoneadm -z mapi list -p | cut -d: -f3`
    [ "$zstate" != "running" ] && fatal "the mapi zone must be running"

    echo "Trimming database"

    setup_pgpass_file

    echo \
 "delete from dataset_messages where created_at < now() - interval  '1 hour';" \
        | zlogin mapi /opt/local/bin/psql -Upostgres mapi
    echo "vacuum ANALYZE" | zlogin mapi /opt/local/bin/psql -Upostgres mapi

    [ $RM_PG_PASSFILE == 1 ] && rm -f $RM_PG_PASSFILE
}

function dump_capi
{
    zstate=`zoneadm -z capi list -p | cut -d: -f3`
    [ "$zstate" != "running" ] && fatal "the capi zone must be running"

    echo "Dump CAPI for database conversion"

    local passfile=/zones/capi/root/root/.pgpass
    local rmpass=0
    if [ ! -f $passfile ]; then
        local pgrespass=`nawk -F= '{
            if ($1 == "POSTGRES_PW")
                print substr($2, 2, length($2) - 2)
        }' /zones/capi/root/opt/smartdc/etc/zoneconfig`
        [ -z "$pgrespass" ] && \
            fatal "Missing .pgpass file and no postgres password in zoneconfig"
        echo "127.0.0.1:*:*:postgres:${pgrespass}" > $passfile
        chmod 600 $passfile
        rmpass=1
    fi

    mkdir -p $SDC_UPGRADE_DIR/capi_dump
    tables=`zlogin capi /opt/local/bin/psql -h127.0.0.1 -Upostgres -w \
        -Atc '\\\dt' capi | cut -d '|' -f2`
    for i in $tables
    do
        zlogin capi /opt/local/bin/pg_dump -Fp -w -a -EUTF-8 -Upostgres \
            -h127.0.0.1 -t $i capi >$SDC_UPGRADE_DIR/capi_dump/$i.dump
        [ $? != 0 ] && fatal "dumping the CAPI database"
    done

    shutdown_zone capi

    [ $rmpass == 1 ] && rm -f $passfile

    echo "Transforming CAPI postgres dumps to LDIF"
    $ROOT/capi2ldif.sh $SDC_UPGRADE_DIR/capi_dump $CONFIG_capi_admin_uuid \
        > $SDC_UPGRADE_DIR/capi_dump/ufds.ldif \
        2>$SDC_UPGRADE_DIR/capi_conversion_issues.txt
    [ $? != 0 ] && fatal "transforming the CAPI dumps"
    [ -s $SDC_UPGRADE_DIR/capi_conversion_issues.txt ] && \
        echo "After the upgrade, " \
            "review CAPI issues in capi_conversion_issues.txt"
}

function dump_mapi_live
{
    echo "Dump MAPI (live responses) for data conversion"
    mkdir -p $SDC_UPGRADE_DIR/mapi_dump
    sdc-mapi /datasets | json -H >$SDC_UPGRADE_DIR/mapi_dump/datasets.json
    [ $? != 0 ] && fatal "getting MAPI datasets failed"

    echo "Transforming MAPI datasets to IMGAPI manifest format"
    DUMP_DIR=$SDC_UPGRADE_DIR/mapi_dump node -e '
        var fs = require("fs");
        var dumpDir = process.env.DUMP_DIR;
        var d = JSON.parse(fs.readFileSync(dumpDir + "/datasets.json"));
        d.forEach(function (image) {
            image._local_path = "/usbkey/datasets/" + image.files[0].path;
            delete image.id;
            delete image.uri;
            delete image.default;
            delete image.imported_at;

            // Leave image.creator_uuid instead of image.owner. This is
            // the signifier to IMGAPI that this is a legacy dsmanifest
            // to normalize.

            // Drop MAPI null value.
            if (!image.restricted_to_uuid) delete image.restricted_to_uuid;
            if (!image.inherited_directories)
                delete image.inherited_directories;
            if (!image.owner_uuid) delete image.owner_uuid;
            if (!image.cpu_type) delete image.cpu_type;
            if (!image.nic_driver) delete image.nic_driver;
            if (!image.disk_driver) delete image.disk_driver;
            if (!image.image_size) delete image.image_size;

            // Default is true and MAPI did not bother with the
            // null-as-default subtlety.
            if (image.generate_passwords)
                delete image.generate_passwords;
            // MAPI had {} as (guessing) the null data-mapper value.
            if (!Array.isArray(image.users))
                delete image.users;
            // IMGAPI wants published_at as "YYYY-MM-DDTHH:MM:SS(.SSS)Z"
            // but MAPI gives, e.g. "2011-11-18T01:41:40+00:00".
            image.published_at = (image.published_at || image.created_at).replace(/\+00:00$/, "Z");
            image.files.forEach(function (file) {
                delete file.path;
                delete file.url;
            });

            // DSAPI did not have disabled support, but MAPI does.
            image.disabled = (image.disabled_at !== null);
            delete image.disabled_at;
        });
        fs.writeFileSync(dumpDir + "/images.json",
            JSON.stringify(d, null, 2) + "\n");
        "Done transforming MAPI datasets."
        '
    [ $? != 0 ] && fatal "transforming MAPI datasets failed"
}

function setup_pgpass_file
{
    PG_PASSFILE=/zones/mapi/root/root/.pgpass
    RM_PG_PASSFILE=0
    if [ ! -f $PG_PASSFILE ]; then
        local pgrespass=`nawk -F= '{
            if ($1 == "POSTGRES_PW")
                print substr($2, 2, length($2) - 2)
        }' /zones/mapi/root/opt/smartdc/etc/zoneconfig`
        [ -z "$pgrespass" ] && \
            fatal "Missing .pgpass file and no postgres password in zoneconfig"
        echo "localhost:*:*:postgres:${pgrespass}" > $PG_PASSFILE
        chmod 600 $PG_PASSFILE
        RM_PG_PASSFILE=1
    fi
}

function dump_mapi_tables
{
    mkdir -p $1

    for i in $MTABLES
    do
        # Skip dumping these tables.  Some of them are very large, take a
        # long time to dump, and we don't consume these anyway.
        case "$i" in
        "dataset_messages")		continue ;;
        "provisioner_messages")		continue ;;
        "ur_messages")			continue ;;
        "zone_tracker_messages")	continue ;;
        esac

        zlogin mapi /opt/local/bin/pg_dump -Fp -w -a -EUTF-8 -Upostgres \
            -t $i mapi >$1/$i.dump
        [ $? != 0 ] && fatal "dumping the MAPI database"
    done
}

function dump_mapi
{
    zstate=`zoneadm -z mapi list -p | cut -d: -f3`
    [ "$zstate" != "running" ] && fatal "the mapi zone must be running"

    echo "Dump MAPI for database conversion"

    setup_pgpass_file

    MTABLES=`zlogin mapi /opt/local/bin/psql -Upostgres -w -Atc '\\\dt' mapi | \
        cut -d '|' -f2`

    dump_mapi_tables $SDC_UPGRADE_DIR/mapi_dump
    shutdown_zone mapi

    [ $RM_PG_PASSFILE == 1 ] && rm -f $RM_PG_PASSFILE

    ulimit -Sn 8192

    echo "Transforming MAPI postgres dumps to moray"
    $ROOT/mapi2moray $SDC_UPGRADE_DIR/mapi_dump \
        $CONFIG_datacenter_name \
        $CONFIG_capi_admin_uuid \
        > $SDC_UPGRADE_DIR/mapi2moray.out 2>&1
    [ $? != 0 ] && fatal "transforming the MAPI dumps to moray"

    mv $SDC_UPGRADE_DIR/mapi_dump/pkgids.out $SDC_UPGRADE_DIR

    $ROOT/mapi2alias.sh $SDC_UPGRADE_DIR/mapi_dump \
        > $SDC_UPGRADE_DIR/aliases.out 2>&1
    [ $? != 0 ] && fatal "generating aliases file"

    $ROOT/mapi2ctime.sh $SDC_UPGRADE_DIR/mapi_dump \
        > $SDC_UPGRADE_DIR/cr_time.out 2>&1
    [ $? != 0 ] && fatal "generating create_time file"

    $ROOT/mapi2tags.sh $SDC_UPGRADE_DIR/mapi_dump \
        > $SDC_UPGRADE_DIR/tags.out 2>&1
    [ $? != 0 ] && fatal "generating tags file"

    $ROOT/mapi2notes.sh $SDC_UPGRADE_DIR/mapi_dump \
        > $SDC_UPGRADE_DIR/notes.out 2>&1
    [ $? != 0 ] && fatal "generating notes file"

    get_net_uuid "admin"
    ADMIN_NET_UUID=$NET_UUID
    get_net_uuid "external"
    EXTERNAL_NET_UUID=$NET_UUID
}

function get_net_uuid
{
    NET_UUID=`nawk -F, -v type=$1 '{
        split($1, a, ":")
        nm = substr(a[2], 2, length(a[2]) - 2)
        if (nm == type) {
            for (i = 2; i < NF; i++) {
                split($i, a, ":")
                if (a[1] == "\"uuid\"") {
                    val = substr(a[2], 2, length(a[2]) - 2)
                    print val
                }
            }
        }
    }' $SDC_UPGRADE_DIR/mapi_dump/napi_networks.moray`
}

# Use a subset of the table dump from mapi to find all zones with IP addresses
# on the admin network. We do this dump before we start the upgrade, so we
# will re-dump later to be sure we have the latest data.
function dump_mapi_netinfo
{
    zstate=`zoneadm -z mapi list -p | cut -d: -f3`
    [ "$zstate" != "running" ] && fatal "the mapi zone must be running"

    echo "Checking MAPI network configuration"

    setup_pgpass_file

    MTABLES="nic_tags networks subnets network_ips nic_nic_tags nics ips"
    MTABLES="$MTABLES network_pool_networks network_pools vms zones servers"
    MTABLES="$MTABLES packages package_network_lists"

    dump_mapi_tables /tmp/mapi_dump

    [ $RM_PG_PASSFILE == 1 ] && rm -f $RM_PG_PASSFILE

    ulimit -Sn 8192

    $ROOT/mapi2moray /tmp/mapi_dump \
        $CONFIG_datacenter_name \
        $CONFIG_capi_admin_uuid \
        > /tmp/mapi2moray-netinfo.out 2>&1
    [ $? != 0 ] && fatal "transforming the MAPI net dumps to moray"

    for i in `
    nawk '/\"nic_tag\":\"admin\"/{
        p = index($0, "\"ip\":\"")
        if (p) {
            p += 6
            s = substr($0, p)
            p = index(s, "\"") - 1
            printf("%s\n", substr(s, 1, p))
        }
    }' < /tmp/mapi_dump/napi_nics.moray`
    do
        num_to_ip $i
        echo $ip_addr >> /tmp/admin_ips.txt
    done

    rm -rf /tmp/mapi_dump
}

convert_portal_zone()
{
    zoneadm -z portal list -p >/dev/null 2>&1
    [ $? -ne 0 ] && return

    zonecfg -z portal \ "select net physical=portal1; " \
        "set physical=net1; " \
        "add property (name=netmask,value=\"$CONFIG_external_netmask\"); end"

    mv /zones/portal/root/etc/hostname.portal1 \
       /zones/portal/root/etc/hostname.net1

    # switch to new hostname.net1 file format
    local old=`cat /zones/portal/root/etc/hostname.net1`
    echo "$old up" >/zones/portal/root/etc/hostname.net1
}

function shutdown_zone
{
	echo "Shutting down zone: $1"
	zlogin $1 /usr/sbin/shutdown -y -g 0 -i 5 1>&4 2>&1

	# Check for zone being down and halt it forcefully if needed
	local cnt=0
	while [ $cnt -lt 18 ]; do
		sleep 5
		local zstate=`zoneadm -z $1 list -p | cut -f3 -d:`
		[ "$zstate" == "installed" ] && break
		cnt=$(($cnt + 1))
	done

	# After 90 seconds, shutdown harder
	if [ $cnt == 18 ]; then
		echo "Forced shutdown of zone: $1"
		zlogin $1 svcs 1>&4 2>&1
		ps -fz $1 1>&4 2>&1
		zoneadm -z $1 halt
	fi
}

# Shutdown all core zones.
function shutdown_sdc_zones
{
	for zone in `zoneadm list`
	do
		[[ "$zone" == "global" ]] && continue
		shutdown_zone $zone
	done
}

function check_versions
{
	new_version=$(cat ${ROOT}/VERSION)

	existing_version=$(cat ${usbmnt}/version 2>/dev/null)
	[[ -z ${existing_version} ]] && \
	    fatal "unable to find version file in ${usbmnt}"

	# Check version to ensure it's possible to apply this update.
	# We only support upgrading from 6.5.4 or later builds.  The 6.5.4
	# build date is in the version string and hardcoded in this script.
	v_old=`echo $existing_version | \
	    nawk -F. '{split($1, f, "T"); print f[1]}'`
	[ $v_old -lt $VERS_6_5_4 ] && \
	    fatal "the system must be running at least SDC 6.5.4 to be upgraded"

	printf "Upgrading from %s\n            to %s\n" \
	    ${existing_version} ${new_version}
}

function upgrade_usbkey
{
    local console=

    echo "Upgrading the USB key"

    # Remove obsolete system-zone info
    rm -rf ${usbmnt}/zones/* /usbkey/zones/*

    # Remove obsolete datasets & data only from the key
    rm -rf ${usbmnt}/datasets/* ${usbmnt}/data/*

    # The datasets subdir is almost 3GB and takes forever to copy to the key.
    # We really only need the datasets in the cache dir to proceed.

    local usbupdate=$(ls ${ROOT}/usbkey/*.tgz | tail -1)
    (cd ${usbmnt} && gzcat ${usbupdate} | \
         gtar --no-same-owner --exclude=datasets -xf -)
    [ $? != 0 ] && fatal_rb "upgrading USB key"

    (cd ${usbcpy} && gzcat ${usbupdate} | \
         gtar --no-same-owner --xform 's/.*/\L&/' -xf - datasets)
    [ $? != 0 ] && fatal_rb "extracting datasets"

    #
    # Save the current console device as the default.  Also, since we know
    # this to be a HN, set the default boot option to Live instead of PXE.
    # We only modify the template because we are going to call switch_platform
    # soon which will regenerate the actual menu.
    #
    console=$(bootparams | grep ^console= | cut -d= -f2)
    [[ -z "${console}" ]] && console=text
    sed -e "s/^variable os_console.*/variable os_console ${console}/" \
	-e "s/^default.*/default 1/" \
	< ${usbmnt}/boot/grub/menu.lst.tmpl \
	> /tmp/menu.lst.tmpl.new
    mv -f /tmp/menu.lst.tmpl.new ${usbmnt}/boot/grub/menu.lst.tmpl

    (cd ${usbmnt} && rsync -a --exclude private --exclude os * ${usbcpy})
    [ $? != 0 ] && fatal_rb "syncing USB key to disk"
}

function switch_platform
{
    local vers=$1
    local hashfile="/platform/i86pc/amd64/boot_archive.hash"
    local menulst="${usbmnt}/boot/grub/menu.lst"

    rm -f ${menulst}
    while read input; do
        set -- $input
        output=$(echo "$input" | sed -e "s|/PLATFORM/|/os/${vers}/platform/|")
        set -- $output
        if [[ "$1" = "module" ]] && [[ "${2##*.}" = "hash" ]] && \
            [[ ! -f "${usbcpy}/os/${vers}${hashfile}" ]]; then
            continue
        fi
        eval echo '${output}' >> ${menulst}
    done < "${menulst}.tmpl"
}

ip_to_num()
{
    IP=$1

    OLDIFS=$IFS
    IFS=.
    set -- $IP
    num_a=$(($1 << 24))
    num_b=$(($2 << 16))
    num_c=$(($3 << 8))
    num_d=$4
    IFS=$OLDIFS

    num=$((num_a + $num_b + $num_c + $num_d))
}

num_to_ip()
{
    NUM=$1

    fld_d=$(($NUM & 255))
    NUM=$(($NUM >> 8))
    fld_c=$(($NUM & 255))
    NUM=$(($NUM >> 8))
    fld_b=$(($NUM & 255))
    NUM=$(($NUM >> 8))
    fld_a=$NUM

    ip_addr="$fld_a.$fld_b.$fld_c.$fld_d"
}

# Save the allocated CN IP addrs.
function dump_server_addrs
{
    for i in `curl -i -s -u admin:$CONFIG_mapi_http_admin_pw \
        $CONFIG_mapi_client_url/servers | json | nawk '{
            if ($1 == "\"hostname\":")
                hn = substr($2, 2, length($2) - 3)

            if ($1 == "\"ip_address\":") {
                if ($2 == "null,") {
                    printf("WARNING: server %s has no IP address\n", hn) \
                        > "/dev/stderr"
                    next
                }
                ip = substr($2, 2, length($2) - 3)
                print ip
            }
        }'`
    do
        [ "$i" == "$CONFIG_admin_ip" ] && continue
        echo $i >> /tmp/admin_ips.txt
    done
}

# Load the allocated admin net IP addrs so we can check for collisions when
# allocating IPs for the new core zones.
function load_admin_ip_addrs
{
    sort -u -o /tmp/admin_ips.txt /tmp/admin_ips.txt

    ADMIN_ADDRS_IN_USE=0

    for i in `cat /tmp/admin_ips.txt`
    do
        ADMIN_ADDRS_IN_USE=$(($ADMIN_ADDRS_IN_USE + 1))
        ip_to_num $i
        ADMIN_IP[$num]=1
    done
}

# Allocate an unused IP addr from the dhcp range
function allocate_ip_addr
{
    i=$dhcp_start
    while [[ $i -le $dhcp_end ]]
    do
        if [ -z "${ADMIN_IP[$i]}" ]; then
            ADMIN_IP[$i]=1
            num_to_ip $i
            # keep track of these so we can reserve them later
            echo "$ip_addr" >>$SDC_UPGRADE_DIR/allocated_addrs.txt
            return
        fi
        i=$(($i + 1))
    done

    # No free addrs - this shouldn't happen since we checked up front, but
    # just in case...
    fatal_rb "allocating an IP address, the DHCP range is exhausted"
}

# Save the external network IP addresses so we can re-use that info after the
# upgrade.
function save_zone_addrs
{
    cat /dev/null > $SDC_UPGRADE_DIR/ext_addrs.txt
    for i in `ls /usbkey/zones`
    do
        local addr=`zonecfg -z $i info net 2>/dev/null | nawk '{
            if ($1 == "global-nic:" && $2 == "external")
                found = 1
            if (found && $1 == "property:") {
                if (index($2, "name=ip,") != 0) {
                    p = index($2, "value=")
                    s = substr($2, p + 7)
                    p = index(s, "\"")
                    s = substr(s, 1, p - 1)
                    print s
                    exit 0
                }
            }
        }'`
        [ -n "$addr" ] && echo "$i $addr" >> $SDC_UPGRADE_DIR/ext_addrs.txt
    done
}

# Since the zone datasets have been renamed for rollback, we can't use
# zoneadm uninstall.  Instead mark and delete.
function delete_sdc_zones
{
	for zone in $ZONES6X
	do
		[[ "$zone" == "capi" && $CAPI_FOUND == 0 ]] && continue
		[[ "$zone" == "portal" ]] && continue

		echo "Deleting zone: $zone"
		zoneadm -z $zone mark -F configured
		[ $? != 0 ] && fatal_rb "marking zone $zone"
		zonecfg -z $zone delete -F
		[ $? != 0 ] && fatal_rb "deleting zone $zone"
	done
}

# Converts an IP and netmask to a network
# For example: 10.99.99.7 + 255.255.255.0 -> 10.99.99.0
# Each field is in the net_a, net_b, net_c and net_d variables.
# Also, host_addr stores the address of the host w/o the network number (e.g.
# 7 in the 10.99.99.7 example above).
ip_netmask_to_haddr()
{
	IP=$1
	NETMASK=$2

	OLDIFS=$IFS
	IFS=.
	set -- $IP
	net_a=$1
	net_b=$2
	net_c=$3
	net_d=$4
	addr_d=$net_d

	set -- $NETMASK
	net_a=$(($net_a & $1))
	net_b=$(($net_b & $2))
	net_c=$(($net_c & $3))
	net_d=$(($net_d & $4))
	host_addr=$(($addr_d & ~$4))

	IFS=$OLDIFS
}

# Fix up the USB key config file
function cleanup_config
{
	echo "Cleaning up configuration"
	mount_usbkey

	cat <<-SED_DONE >/tmp/upg.$$
	/^admin_gateway=/d
	/^compute_node_default_gateway=/d
	/^adminui_admin_ip=/d
	/^adminui_external_ip=/d
	/^adminui_admin_pw=/d
	/^assets_admin_ip=/d
	/^assets_admin_pw=/d
	/^ca_admin_ip=/d
	/^ca_client_url=/d
	/^ca_admin_pw=/d
	/^capi_/d
	/^dnsapi_/d
	/^dhcpd_admin_ip=/d
	/^dhcp_next_server=/d
	/^dhcp_lease_time=/d
	/^dhcpd_admin_pw=/d
	/^mapi_/d
	/^portal_/d
	/^cloudapi_admin_ip=/d
	/^cloudapi_external_ip=/d
	/^cloudapi_external_url=/d
	/^cloudapi_admin_pw=/d
	/^rabbitmq_admin_ip=/d
	/^rabbitmq=/d
	/^rabbitmq_admin_pw=/d
	/^riak_/d
	/^billapi_/d
	/^# datacenter_headnode_id/d
	/^# for this headnode within that datacenter/d
	/^datacenter_headnode_id=/d
	/^# This should not be changed/d
	/^initial_script=/d
	/^# capi/d
	/^# billapi/d
	/^# portal/d
	SED_DONE

	sed -f /tmp/upg.$$ </mnt/usbkey/config >/tmp/config.$$

	# Calculate fixed addresses for some of the new zones.
	# Using the model from the 6.x prompt-config.sh we use the old
	# adminui_admin_ip address as the starting point for the zones and
	# increment up.
	#
	# We first want to re-use the 11 addrs before we eat into the dhcp
	# range for the additional addrs we need. We may have 4 additional
	# addrs to use as well, if the customer has setup their config in the
	# default manner.

	# 1
	adminui_admin_ip="$CONFIG_adminui_admin_ip"

	# 2
	assets_admin_ip="$CONFIG_assets_admin_ip"

	# 3
	ca_admin_ip="$CONFIG_ca_admin_ip"

	# 4 - was capi, re-use for ufds if local, otherwise alloc new IP
	if [ $CAPI_FOUND == 1 ]; then
	    ufds_admin_ip="$CONFIG_capi_admin_ip"
	    ufds_external_ip="$CONFIG_capi_external_ip"
	    ufds_external_vlan="$CONFIG_capi_external_vlan"
	else
	    allocate_ip_addr
	    ufds_admin_ip="$ip_addr"
	    # re-use billapi external IP for ufds since billapi no longer exists
	    ufds_external_ip="$CONFIG_billapi_external_ip"
	    ufds_external_vlan="$CONFIG_external_vlan_id"
	fi
	if [ -z "$ufds_external_vlan" ]; then
	    ufds_ext_vlan="# ufds_external_vlan=0"
	else
	    ufds_ext_vlan="ufds_external_vlan=$ufds_external_vlan"
	fi

	# 5
	dhcpd_admin_ip="$CONFIG_dhcpd_admin_ip"

	# 6 - was mapi, use for napi
	napi_admin_ip="$CONFIG_mapi_admin_ip"

	# 7 - was cloudapi, use for binder
	binder_admin_ip="$CONFIG_cloudapi_admin_ip"

	# 8
	rabbitmq_admin_ip="$CONFIG_rabbitmq_admin_ip"

	# 9 - was billapi, use for moray
	moray_admin_ip="$CONFIG_billapi_admin_ip"

	# 10 - was riak, use for workflow
	workflow_admin_ip="$CONFIG_riak_admin_ip"

	# Start eating into the dhcp range for the rest of the new zones.

	allocate_ip_addr
	manatee_admin_ip="$ip_addr"

	allocate_ip_addr
	imgapi_admin_ip="$ip_addr"

	allocate_ip_addr
	cnapi_admin_ip="$ip_addr"

	allocate_ip_addr
	redis_admin_ip="$ip_addr"

	allocate_ip_addr
	amon_admin_ip="$ip_addr"

	allocate_ip_addr
	dapi_admin_ip="$ip_addr"

	allocate_ip_addr
	fwapi_admin_ip="$ip_addr"

	allocate_ip_addr
	vmapi_admin_ip="$ip_addr"

	allocate_ip_addr
	keyapi_admin_ip="$ip_addr"

	allocate_ip_addr
	usageapi_admin_ip="$ip_addr"

	allocate_ip_addr
	sapi_admin_ip="$ip_addr"

	if [[ -z "$CONFIG_adminui_external_vlan" ]]; then
	   usage_ext_vlan="# usageapi_external_vlan=0"
	else
	   usage_ext_vlan="usageapi_external_vlan=$CONFIG_adminui_external_vlan"
	fi

	# Allocate 4 more IP addrs for binder instances
	binder_resolver_ips=$binder_admin_ip
	for i in {0..3}; do
		allocate_ip_addr
		binder_resolver_ips="$binder_resolver_ips,$ip_addr"
	done

	#
	# The floor for default DHCP lease time (for CNs) is 30 days.
	#
	dhcp_lease_time=${CONFIG_dhcp_lease_time}
	if [[ "${CONFIG_dhcp_lease_time}" -lt 2592000 ]]; then
		dhcp_lease_time=2592000
	fi

	cat <<-DONE >>/tmp/config.$$

	# UUIDs for the admin and external networks
	admin_uuid=$ADMIN_NET_UUID
	external_uuid=$EXTERNAL_NET_UUID

	adminui_admin_ips=$adminui_admin_ip
	adminui_external_ips=$CONFIG_adminui_external_ip
	adminui_domain=adminui.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	assets_admin_ip=$assets_admin_ip
	assets_admin_ips=$assets_admin_ip

	dhcpd_admin_ip=$dhcpd_admin_ip
	dhcpd_admin_ips=$dhcpd_admin_ip
	dhcpd_domain=dhcpd.${CONFIG_datacenter_name}.${CONFIG_dns_domain}
	dhcp_lease_time=$dhcp_lease_time

	rabbitmq_admin_ip=$rabbitmq_admin_ip
	rabbitmq_admin_ips=$rabbitmq_admin_ip
	rabbitmq=guest:guest:${rabbitmq_admin_ip}:5672
	rabbitmq_domain=rabbitmq.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	ca_admin_ips=$ca_admin_ip
	ca_domain=ca.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	binder_root_pw=$CONFIG_adminui_root_pw
	binder_admin_ips=$binder_admin_ip

	# Reserved IPs for binder instances
	binder_resolver_ips=$binder_resolver_ips

	manatee_root_pw=$CONFIG_adminui_root_pw
	manatee_admin_ips=$manatee_admin_ip

	moray_root_pw=$CONFIG_adminui_root_pw
	moray_admin_ips=$moray_admin_ip
	moray_domain=moray.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	imgapi_root_pw=$CONFIG_adminui_root_pw
	imgapi_admin_ips=$imgapi_admin_ip
	imgapi_domain=imgapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	dapi_root_pw=$CONFIG_adminui_root_pw
	dapi_admin_ips=$dapi_admin_ip
	dapi_domain=dapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	vmapi_root_pw=$CONFIG_adminui_root_pw
	vmapi_admin_ips=$vmapi_admin_ip
	vmapi_domain=vmapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	keyapi_root_pw=$CONFIG_adminui_root_pw
	keyapi_admin_ips=$keyapi_admin_ip
	keyapi_domain=keyapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	sdcsso_root_pw=$CONFIG_adminui_root_pw
	sdcsso_domain=sdcsso.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	amon_admin_ips=$amon_admin_ip
	amon_root_pw=$CONFIG_adminui_root_pw
	amon_domain=amon.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	redis_admin_ips=$redis_admin_ip
	redis_root_pw=$CONFIG_adminui_root_pw
	redis_domain=redis.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	dsapi_url=https://datasets.joyent.com
	dsapi_http_user=honeybadger
	dsapi_http_pass=IEatSnakes4Fun

	$usage_ext_vlan
	usageapi_root_pw=$CONFIG_capi_root_pw
	usageapi_admin_ips=$usageapi_admin_ip
	usageapi_domain=usageapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	cnapi_root_pw=$CONFIG_adminui_root_pw
	cnapi_admin_ips=$cnapi_admin_ip
	cnapi_client_url=http://${cnapi_admin_ip}:80
	cnapi_domain=cnapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	napi_root_pw=$CONFIG_adminui_root_pw
	napi_admin_ips=$napi_admin_ip
	napi_client_url=http://${napi_admin_ip}:80
	napi_mac_prefix=90b8d0
	napi_domain=napi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	workflow_root_pw=$CONFIG_adminui_root_pw
	workflow_admin_ips=$workflow_admin_ip
	workflow_domain=workflow.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	fwapi_root_pw=$CONFIG_adminui_root_pw
	fwapi_admin_ips=$fwapi_admin_ip
	fwapi_client_url=http://${fwapi_admin_ip}:80
	fwapi_domain=fwapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	sapi_admin_ips=$sapi_admin_ip
	sapi_domain=sapi.${CONFIG_datacenter_name}.${CONFIG_dns_domain}

	show_setup_timers=true
	serialize_setup=true

	ufds_is_master=$CONFIG_capi_is_local
	ufds_admin_ips=$ufds_admin_ip
	ufds_external_ips=$ufds_external_ip
	$ufds_ext_vlan
	ufds_admin_uuid=$CONFIG_capi_admin_uuid
	ufds_ldap_root_dn=cn=root
	ufds_ldap_root_pw=secret
	# Legacy CAPI parameters
	# Required by SmartLogin:
	capi_client_url=http://$ufds_admin_ip:8080
	ufds_domain=ufds.${CONFIG_datacenter_name}.${CONFIG_dns_domain}
	DONE

	if [[ $CAPI_FOUND == 1 ]]; then
		cat <<-UDONE1 >>/tmp/config.$$
		ufds_admin_login=$CONFIG_capi_admin_login
		ufds_admin_pw=$CONFIG_capi_admin_pw
		ufds_admin_email=$CONFIG_capi_admin_email
		UDONE1
	else
		# Since no capi-specific values, we re-use the mapi values
		cat <<-UDONE2 >>/tmp/config.$$
		ufds_admin_login=$CONFIG_mapi_http_admin_user
		ufds_admin_pw=$CONFIG_mapi_admin_pw
		ufds_admin_email=$CONFIG_mail_to
		ufds_remote_ip=$MASTER_UFDS_IP
		UDONE2
	fi

	cp /tmp/config.$$ /mnt/usbkey/config
 	cp /mnt/usbkey/config /usbkey/config

	rm -f /tmp/config.$$ /tmp/upg.$$

	# Load the new pkg values from the upgrade conf.generic into variables.
	eval $(cat ${ROOT}/conf.generic | sed -e "s/^ *//" | grep -v "^#" | \
	    grep "^[a-zA-Z]" | sed -e "s/^/GENERIC_/")

	pkgs=`set | nawk -F=  '/^GENERIC_pkg_/ {print $2}'`

	# Convert generic config
	# Remove obsolete entries and adjust the core-zone memory caps
	# in the generic file
	cat <<-SED_DONE >/tmp/upg.$$
		/^adminui_cpu_shares/d
		/^adminui_max_lwps/d
		/^adminui_memory_cap/d
		/^dhcpd_cpu_shares/d
		/^dhcpd_max_lwps/d
		/^dhcpd_memory_cap/d
		/^assets_/d
		/^billapi_/d
		/^ca_/d
		/^capi_/d
		/^cloudapi_/d
		/^mapi_/d
		/^portal_/d
		/^rabbitmq_/d
		/^riak_/d
		/^sdc_version/d
		/^# If the capi_allow_file/d
		/^# CIDR addresses like:/d
		/^# 10.99.99.0\/24/d
		/^# 10.88.88.0\/24/d
		/^# These networks are then the/d
		/^# this file existing and being populated/d
	SED_DONE

	sed -f /tmp/upg.$$ </mnt/usbkey/config.inc/generic \
	    >/tmp/config.$$

	# add all pkg_ entries from upgrade generic file
	echo "" >>/tmp/config.$$
	echo "# Pkg entry format:" >>/tmp/config.$$
	echo "#        name:ram:swap:disk:cap:nlwp:iopri:uuid" >>/tmp/config.$$
	echo "#" >>/tmp/config.$$
	echo "# These must start with 0 and increment by 1." >>/tmp/config.$$
	cnt=0
	for i in $pkgs
	do
		echo "pkg_$cnt=$i" >>/tmp/config.$$
		cnt=$((cnt + 1))
	done

	# add new entries
	cat <<-DONE >>/tmp/config.$$

	initial_script=scripts/headnode.sh

	# Positive offset from UTC 0. Used to calculate cron job start times.
	utc_offset=0

	assets_pkg=${GENERIC_assets_pkg}
	sapi_pkg=${GENERIC_sapi_pkg}
	cloudapi_pkg=${GENERIC_cloudapi_pkg}
	sdcsso_pkg=${GENERIC_sdcsso_pkg}
	adminui_pkg=${GENERIC_adminui_pkg}
	amon_pkg=${GENERIC_amon_pkg}
	usageapi_pkg=${GENERIC_usageapi_pkg}
	ca_pkg=${GENERIC_ca_pkg}
	cloudapi_pkg=${GENERIC_cloudapi_pkg}
	cnapi_pkg=${GENERIC_cnapi_pkg}
	dapi_pkg=${GENERIC_dapi_pkg}
	dhcpd_pkg=${GENERIC_dhcpd_pkg}
	imgapi_pkg=${GENERIC_imgapi_pkg}
	manatee_pkg=${GENERIC_manatee_pkg}
	moray_pkg=${GENERIC_moray_pkg}
	keyapi_pkg=${GENERIC_keyapi_pkg}
	sdcsso_pkg=${GENERIC_sdcsso_pkg}
	napi_pkg=${GENERIC_napi_pkg}
	fwapi_pkg=${GENERIC_fwapi_pkg}
	rabbitmq_pkg=${GENERIC_rabbitmq_pkg}
	redis_pkg=${GENERIC_redis_pkg}
	ufds_pkg=${GENERIC_ufds_pkg}
	workflow_pkg=${GENERIC_workflow_pkg}
	vmapi_pkg=${GENERIC_vmapi_pkg}
	binder_pkg=${GENERIC_binder_pkg}
	manta_pkg=${GENERIC_manta_pkg}

	dbconn_retry_after=10
	dbconn_num_attempts=10
	DONE

	cp /tmp/config.$$ /mnt/usbkey/config.inc/generic
	cp /mnt/usbkey/config.inc/generic /usbkey/config.inc/generic
	rm -f /tmp/config.$$ /tmp/upg.$$

	umount_usbkey
}

# We expect the usbkey to already be mounted when we run this
function install_platform
{
	local platformupdate=$(ls ${ROOT}/platform/platform-*.tgz | tail -1)
	if [[ -n ${platformupdate} && -f ${platformupdate} ]]; then
		# 'platformversion' is intentionally global.
		platformversion=$(basename "${platformupdate}" | \
		    sed -e "s/.*\-\(2.*Z\)\.tgz/\1/")
	fi

	[ -z "${platformversion}" ] && \
	    fatal "unable to determine platform version"

	if [[ -d ${usbcpy}/os/${platformversion} ]]; then
		echo \
	    "${usbcpy}/os/${platformversion} already exists, skipping update."
		return
        fi

        # Remove the 6.5.x platforms since they're no longer usable
        # Leave the platforms in /usbkey/os since they're needed by CNs
        rm -rf ${usbmnt}/os/*

	echo "Unpacking ${platformversion} to ${usbmnt}/os"
	(mkdir -p ${usbmnt}/os/${platformversion} \
	 && cd ${usbmnt}/os/${platformversion} \
	 && gzcat ${platformupdate} | tar -xf - 2>/tmp/install_platform.log \
	 && mv platform-* platform
	)
	[ $? != 0 ] && \
	    fatal_rb "unable to install the new platform onto the USB key"

	[[ -f ${usbmnt}/os/${platformversion}/platform/root.password ]] && \
	    mv -f ${usbmnt}/os/${platformversion}/platform/root.password \
		${usbmnt}/private/root.password.${platformversion}

	echo "Unpacking ${platformversion} to ${usbcpy}/os"
	(mkdir -p ${usbcpy}/os/${platformversion} \
	 && cd ${usbcpy}/os/${platformversion} \
	 && gzcat ${platformupdate} | \
            gtar --xform 's/.*/\L&/' -xf - 2>/tmp/copy_platform.log \
	 && mv platform-* platform
	)
	[ $? != 0 ] && \
	    fatal_rb "unable to install the new platform onto the disk"
}

function wait_and_clear
{
	while [ true ]; do
		# It seems like jobs -p can miscount if we don't run jobs first
		jobs >/dev/null
		local cnt=`jobs -p | wc -l`
		[ $cnt -eq 0 ] && break
		for s in `svcs -x | nawk '/^svc:/ {print $1}'`
		do
			svcadm clear $s
		done
		sleep 1
	done
}

# Generate a script with embedded data that will update each zone configuration
# on each compute node. The embedded data is the zone/vm aliases, the zone
# creation timestamp, the zone's corrected billing id, and the zone's tags.json.
# In addition to the embedded data in the script, the code will process that
# data and update each of the zones that are local to that specific compute
# node.
#
# The script must be idempotent so it can re-run if we've rolled back and
# upgraded again.
function update_vm_attrs
{
    echo "Updating the VM configurations on each compute node"

    echo "cat <<DONE1 >/tmp/aliases" >/tmp/upd_cn
    cat $SDC_UPGRADE_DIR/aliases.out >>/tmp/upd_cn
    echo "DONE1" >>/tmp/upd_cn
    echo "" >>/tmp/upd_cn

    echo "cat <<DONE2 >/tmp/cr_time" >>/tmp/upd_cn
    cat $SDC_UPGRADE_DIR/cr_time.out >>/tmp/upd_cn
    echo "DONE2" >>/tmp/upd_cn
    echo "" >>/tmp/upd_cn

    echo "cat <<DONE3 >/tmp/tags" >>/tmp/upd_cn
    cat $SDC_UPGRADE_DIR/tags.out >>/tmp/upd_cn
    echo "DONE3" >>/tmp/upd_cn
    echo "" >>/tmp/upd_cn

    echo "cat <<DONE4 >/tmp/pkg_ids" >>/tmp/upd_cn
    cat $SDC_UPGRADE_DIR/pkgids.out >>/tmp/upd_cn
    echo "DONE4" >>/tmp/upd_cn
    echo "" >>/tmp/upd_cn

    cat <<-"PROG" >>/tmp/upd_cn
	rm -f /tmp/upd.log
	for i in `zoneadm list -c`
	do
	  [ "$i" == "global" ] && continue

	  # use /tmp/aliases to add an alias to the zone
	  zonecfg -z $i remove attr name=alias 2>/dev/null
	  v=`nawk -v n=$i '{if ($1 == n) {print $2; exit 0}}' /tmp/aliases`
	  if [ -n "$v" ]; then
	    echo "=== alias $i $v" >>/tmp/upd.log
	    zonecfg -z $i \
	    "add attr; set name=alias; set type=string; set value=\"$v\"; end" \
	    >>/tmp/upd.log 2>&1
	  fi

	  # use /tmp/cr_time to add the creation time to the zone
	  zonecfg -z $i remove attr name=create-timestamp 2>/dev/null
	  v=`nawk -v n=$i '{if ($1 == n) {print $2; exit 0}}' /tmp/cr_time`
	  if [ -n "$v" ]; then
	    echo "=== crtim $i $v" >>/tmp/upd.log
	    zonecfg -z $i \
	    "add attr; set name=create-timestamp; set type=string; set value=\"$v\"; end" \
	    >>/tmp/upd.log 2>&1
	  fi

	  # use /tmp/pkg_ids to fix the billing_id on the zone
	  zonecfg -z $i remove attr name=billing-id 2>/dev/null
	  pnm=`zonecfg -z $i info attr name=package-name | \
	    nawk '{if ($1 == "value:") {
	      nm = substr($0, length($1) + 3)
	      if (substr(nm, 1, 1) == "\"")
	          print substr(nm, 2, length(nm) - 2)
	      else
	          print nm
	    }}'`
	  pvr=`zonecfg -z $i info attr name=package-version | \
	    nawk '{if ($1 == "value:") print $2}'`
	  pkey="$pnm $pvr"
	  v=`nawk -v n="$pkey" -F\t '{if ($1 == n) {print $2; exit 0}}' \
	    /tmp/pkg_ids`
	  if [ -n "$v" ]; then
	    echo "=== bllid $i $v" >>/tmp/upd.log
	    zonecfg -z $i \
	    "add attr; set name=billing-id; set type=string; set value=\"$v\"; end" \
	    >>/tmp/upd.log 2>&1
	  fi

	  # use /tmp/tags to put the tag in the zone config dir
	  v=`nawk -v n=$i \
	    '{if ($1 == n) {print substr($0, length($1) + 2); exit 0}}' \
	    /tmp/tags`
	  if [ -n "$v" ]; then
	      echo "=== tags  $i $v" >>/tmp/upd.log
	      mkdir -p /zones/$i/config
	      echo $v > /zones/$i/config/tags.json
	  fi
	done
	PROG

    sdc-oneachnode $OEN_ARGS "rm -f /tmp/upd_cn" >/dev/null
    [ $? != 0 ] && fatal "setting up compute node update"
    sdc-oneachnode $OEN_ARGS -g /tmp/upd_cn >/dev/null
    [ $? != 0 ] && fatal "copying compute node update file"

    sdc-oneachnode $OEN_ARGS "bash /tmp/upd_cn &" >/dev/null
    # ignore errors which are expected on a re-run

    # save for possible re-run on CNs that are currently down
    mkdir -p /var/cn_upgrade
    cp /tmp/upd_cn /var/cn_upgrade
}

function install_agent
{
    local nm=$1

    cp $ROOT/$nm.tgz $assetdir

    mkdir -p /var/cn_upgrade
    cp $ROOT/$nm.tgz /var/cn_upgrade

    local cnt=`sdc-oneachnode $OEN_ARGS "cd /var/tmp;
       curl -kOs $CONFIG_assets_admin_ip:/agents/$nm.tgz;
       /opt/smartdc/agents/bin/agents-npm install /var/tmp/$nm.tgz \
       >/var/tmp/${nm}_install.log 2>&1 &" | \
       egrep -v "^HOST" | wc -l`
    echo "Installed $nm agent on $cnt nodes"
}

echo "$(date -u "+%Y%m%dT%H%M%S") start" >/tmp/upgrade_time

CHECK_ONLY=0
DO_CHECKS=1
AGENTS_ONLY=0
FATAL_CNT=0
while getopts "acC" opt
do
	case "$opt" in
		a)	AGENTS_ONLY=1;;
		c)	CHECK_ONLY=1;;
		C)	DO_CHECKS=0;;
		*)	echo "ERROR: invalid option" >/dev/stderr
			exit 1;;
	esac
done

# Ensure we're a SmartOS headnode
if [[ ${SYSINFO_Bootparam_headnode} != "true" \
    || $(uname -s) != "SunOS" \
    || -z ${SYSINFO_Live_Image} ]]; then

    fatal "this can only be run on a SmartOS headnode."
fi

[[ $CHECK_ONLY == 1 && $AGENTS_ONLY == 1 ]] && fatal "incompatible options"

OEN_ARGS="-t 30 -T 120 -c"
# Get list of any CNs to ignore
skip_cns=`sdc-mapi /servers | nawk '{
        if ($1 == "\"hostname\":")
            hn = substr($2, 2, length($2) - 3)
        if ($1 == "\"current_status\":") {
            st = substr($2, 2, length($2) - 3)
            if (st == "unsetup") {
                printf("%s%s", delim, hn)
                delim=","
            }
        }
    }'`
[ -n "$skip_cns" ] && OEN_ARGS="$OEN_ARGS -x -n $skip_cns"

if [[ $AGENTS_ONLY == 1 ]]; then
    echo "Upgrade compute node agents"

    assetdir=/zones/assets/root/assets/agents
    mkdir -p $assetdir

    install_agent heartbeater-65
    install_agent provisioner-v2-65
    install_agent zonetracker-v2-65

    echo "Compute node agent install is complete"

    # Note that the billapi external IP will be re-used for the new remote ufds
    # zone when that remote HN is upgraded.
    if [[ "$CONFIG_capi_is_local" == "true" ]]; then
        echo
        echo "If you have other datacenters accessing this CAPI master, then" \
             "list the remote"
        echo "ADMINUI, BILLAPI, CloudAPI and Portal external IP addresses in"
        echo "/var/tmp/capi_access before you run the upgrade."
    fi

    exit 0
fi

mount_usbkey
check_versions
umount_usbkey

if [ $DO_CHECKS -eq 1 ]; then
    # Make sure there are no svcs in maintenance. This will break checking later
    # in the upgrade process. Also, we don't want multiple users on the HN in
    # the middle of an upgrade and we want to be sure the zpool is stable.
    maint_svcs=`svcs -x | nawk 'BEGIN {cnt=0} {
       if (substr($0, 1, 4) == "svc:") cnt++
       } END {print cnt}'`
    [ $maint_svcs -gt 0 ] && \
        fatal "there are SMF svcs in maintenance, unable to proceed with" \
            "upgrade."

    nusers=`who | wc -l`
    [ $nusers -gt 1 ] && \
        fatal "there are multiple users logged in, unable to proceed with" \
           "upgrade."

    zpool status zones >/dev/null
    [ $? -ne 0 ] && \
        fatal "the 'zones' zpool has errors, unable to proceed with upgrade."

    # check that we have enough space
    mount_usbkey
    fspace=`df -k /mnt/usbkey | nawk '{if ($4 != "avail") print $4}'`
    umount_usbkey
    # At least 700MB free on key?
    [[ $fspace -lt 700000 ]] && \
        fatal "there is not enough free space on the USB key"
    fspace=`zfs list -o avail -Hp zones`
    # At least 4GB free on disk?
    [[ $fspace -lt 4000000000 ]] && \
        fatal "there is not enough free space in the zpool"
fi

rm -rf /tmp/admin_ips.txt /tmp/mapi_dump
dump_server_addrs
dump_mapi_netinfo
load_admin_ip_addrs

load_sdc_config
check_capi

# Verify there is enough free IP addrs in the dhcp range for the upgrade.
#
# In 6.x we allocated 10 IP addrs (only 9 if no local capi) for the zones on
# the admin net. We also allocated 1 IP addr for the dhcp_next_server entry
# which was unused, but some sites have a conflict on that address, so we
# don't attempt to use it. Thus, we only have 9 or 10 addresses to re-use.
#
# In 7.0 we have 23 admin zones plus 4 reserved IPs for additional binder
# instances, so we need at least 17, and maybe 18, additional addresses out of
# the dhcp range to accomodate the new zones.
#
# XXX each time another new core HN zone is added, we need to bump this up
need_num_addrs=17

ip_to_num $CONFIG_dhcp_range_start
dhcp_start=$num

ip_to_num $CONFIG_dhcp_range_end
dhcp_end=$num

# the dhcp range is inclusive, so add 1
dhcp_total=$(($dhcp_end - $dhcp_start + 1))
dhcp_avail=$(($dhcp_total - $ADMIN_ADDRS_IN_USE))

# Check if we have a local CAPI
if [[ $CAPI_FOUND == 0 ]]; then
     need_num_addrs=$(($need_num_addrs + 1))
fi

[[ $dhcp_avail -lt $need_num_addrs ]] && \
    fatal "there are not enough free IP addresses in the DHCP range to upgrade"

if [[ $CAPI_FOUND == 0 ]]; then
    MASTER_UFDS_IP=`echo $CONFIG_capi_external_url | nawk -F/ '{
        split($3, a, ":")
        print a[1]
    }'`

    if [ $DO_CHECKS -eq 1 ]; then
        # Need to check from adminui since GZ may not get through firewall
        echo -n "Checking connectivity to remote UFDS..."
        zlogin adminui curl -f $MASTER_UFDS_IP:636/ >/dev/null 2>&1
        if [ $? != 52 ]; then
            echo
            fatal "remote UFDS not responding"
        else
            printf "OK\n"
        fi
    fi
fi

if [ $DO_CHECKS -eq 1 ]; then
    echo -n "Checking each compute node for correct agents..."
    num_cn=`sdc-oneachnode $OEN_ARGS hostname | egrep -v "^HOST" | wc -l`
    sdc-oneachnode $OEN_ARGS /opt/smartdc/agents/bin/agents-npm --noreg ls \
        >/tmp/cn_agent.out

    num_hb=`egrep heartbeater@1.0.1 /tmp/cn_agent.out | wc -l`
    num_prov=`egrep provisioner-v2@1.0.11 /tmp/cn_agent.out | wc -l`
    num_zt=`egrep zonetracker-v2@1.0.7 /tmp/cn_agent.out | wc -l`

    if [[ $num_hb != $num_cn ]]; then
        echo
        fatal "The correct hearbeater agents are not installed on each" \
           "compute node"
    fi
    if [[ $num_prov != $num_cn ]]; then
        echo
        fatal "The correct provisioner agents are not installed on each" \
           "compute node"
    fi
    if [[ $num_zt != $num_cn ]]; then
        echo
        fatal "The correct zonetracker agents are not installed on each" \
           "compute node"
    fi
    printf "OK\n"
fi

# End of validation checks, quit now if only validating
if [ $CHECK_ONLY -eq 1 ]; then
    [ $FATAL_CNT -gt 0 ] && exit 1
    echo "No validation errors detected"
    exit 0
fi

trap "" SIGHUP
trap "" SIGINT
trap "" SIGQUIT
trap "" SIGABRT
trap "" SIGPIPE
trap "" SIGALRM
trap "" SIGTERM
trap cleanup EXIT

# Disable cron so scheduled jobs, such as backup, don't interfere with us and
# we don't interfere with them.
svcadm disable cron

# If a backup is already in progress (e.g. from cron), quit
[ -n "`pgrep pg_dump`" ] && \
    fatal "a backup is in progress, upgrade when the backup is complete"

# We might be re-running upgrade again after a rollback, so first cleanup
rm -rf /var/upgrade_failed /var/usb_rollback
mkdir -p $SDC_UPGRADE_DIR
mv /tmp/admin_ips.txt $SDC_UPGRADE_DIR
mv /tmp/upgrade_time $SDC_UPGRADE_DIR

# First trim down dataset_messages since it gets huge
trim_db

# Since we're upgrading from 6.x we cannot shutdown the zones before backing
# up, since 6.x backup depends on the zones running.

# Run full backup with the old sdc-backup code, then unpack the backup archive.
# Double check the existence of backup file.
echo "$(date -u "+%Y%m%dT%H%M%S") backup start" >>$SDC_UPGRADE_DIR/upgrade_time
echo "Creating a backup"
sdc-backup -s datasets -s billapi -s riak -d $SDC_UPGRADE_DIR
[[ $? != 0 ]] && fatal "unable to make a backup"
bfile=`ls $SDC_UPGRADE_DIR/backup-* 2>/dev/null`
[ -z "$bfile" ] && fatal "missing backup file"
echo "$(date -u "+%Y%m%dT%H%M%S") backup end" >>$SDC_UPGRADE_DIR/upgrade_time

# Keep track of the core zone external addresses
save_zone_addrs

dump_mapi_live
# Shutdown the mapi and capi svcs so that the data provided by these zones
# won't change during the dump
zlogin mapi svcadm disable -t mcp_api
if [ $CAPI_FOUND == 1 ]; then
    zlogin capi svcadm disable -t capi
    dump_capi
fi
dump_mapi
echo "$(date -u "+%Y%m%dT%H%M%S") dumps done" >>$SDC_UPGRADE_DIR/upgrade_time

update_vm_attrs

# Now we can shutdown the rest of the zones so we are in an even more stable
# state for the rest of this phase of the upgrade.
shutdown_sdc_zones

# shutdown the smartdc svcs too
echo "stopping svcs"
for i in `svcs -a | nawk '/smartdc/{print $3}'`
do
    svcadm disable $i
done

mkdir $SDC_UPGRADE_DIR/bu.tmp
(cd $SDC_UPGRADE_DIR/bu.tmp; gzcat $bfile | tar xbf 512 -)

# Capture data missed by 6.5.x backup
PLUG_DIR=/zones/cloudapi/root/opt/smartdc/cloudapi/plugins
if [ -d $PLUG_DIR ]; then
    mkdir -p ${SDC_UPGRADE_DIR}/bu.tmp/cloudapi/plugins
    (cd ${PLUG_DIR} && cp -pr * ${SDC_UPGRADE_DIR}/bu.tmp/cloudapi/plugins)
fi

upgrade_zfs_datasets
upgrade_pools

# Setup for rollback
echo "$(date -u "+%Y%m%dT%H%M%S") start rb" >>$SDC_UPGRADE_DIR/upgrade_time
echo "saving data for rollback"
$ROOT/setup_rb.sh
[ $? != 0 ] && fatal "unable to setup for rollback"
echo "$(date -u "+%Y%m%dT%H%M%S") end rb" >>$SDC_UPGRADE_DIR/upgrade_time

trap recover EXIT

# At this point we start doing destructive actions on the HN, so we should
# no longer call "fatal" if we see an error. Intead, call fatal_rb.

echo "$(date -u "+%Y%m%dT%H%M%S") key upgrade start" \
    >>$SDC_UPGRADE_DIR/upgrade_time
mount_usbkey
install_platform
upgrade_usbkey
switch_platform ${platformversion}
umount_usbkey
echo "$(date -u "+%Y%m%dT%H%M%S") key upgrade end" \
    >>$SDC_UPGRADE_DIR/upgrade_time

convert_portal_zone

echo "Deleting existing zones"
delete_sdc_zones

cleanup_config
load_sdc_config

# Remove 6.5.x agent manifests so that svcs won't fail when we boot onto 7.0
#
# This process is execessively complex but if not done carefully we will wedge
# with svcs in maintenance.  We start by removing all but the agents_core.
# Sometimes this leaves one or more agents still installed, so we do it again.
# Finally we remove the agents_core (which should be the only thing left) and
# then clean up the dirs so new agents will install into a fresh environment.
# The wait_and_clear function is used to watch for svcs goint into maintenance
# during this process and clear them so that the agent uninstall can continue.
echo "Deleting old agents"

AGENTS_DIR=/opt/smartdc/agents

TOREMOVE=`/opt/smartdc/agents/bin/agents-npm --no-registry ls installed \
    2>/dev/null | nawk '{print $1}'`
for agent in $TOREMOVE
do
    (echo "$agent" | egrep -s '^atropos@') && continue
    # We have to do agents_core after the others
    (echo "$agent" | egrep -s '^agents_core@') && continue

    # Supress possible npm warning removing CA (See AGENT-392)
    if (echo "$agent" | egrep -s '^cainstsvc'); then
        [ -e $AGENTS_DIR/smf/cainstsvc-default.xml ] && \
            touch $AGENTS_DIR/smf/cainstsvc.xml
    fi

    echo "Uninstall: $agent"
    /opt/smartdc/agents/bin/agents-npm uninstall $agent 1>&4 2>&1 &
    wait_and_clear
done

TOREMOVE=`/opt/smartdc/agents/bin/agents-npm --no-registry ls installed \
    2>/dev/null | nawk '{print $1}'`
for agent in $TOREMOVE
do
    (echo "$agent" | egrep -s '^atropos@') && continue
    # We have to do agents_core after the others
    (echo "$agent" | egrep -s '^agents_core@') && continue

    echo "Uninstall: $agent"
    /opt/smartdc/agents/bin/agents-npm uninstall $agent 1>&4 2>&1 &
    wait_and_clear
done

TOREMOVE=`/opt/smartdc/agents/bin/agents-npm --no-registry ls installed \
    2>/dev/null | nawk '{print $1}'`
for agent in $TOREMOVE
do
    (echo "$agent" | egrep -s '^atropos@') && continue

    echo "Uninstall: $agent"
    /opt/smartdc/agents/bin/agents-npm uninstall $agent 1>&4 2>&1 &
    wait_and_clear
done

for dir in $(ls "$AGENTS_DIR"); do
    case "$dir" in
    db|smf) continue ;;
    *)      rm -fr $AGENTS_DIR/$dir ;;
    esac
done

rm -rf $AGENTS_DIR/smf/*

# Fix up /var
mkdir -m755 -p /var/db/imgadm
mkdir -m755 -p /var/log/vm/logs
touch /var/log/vm/vm.log

cd /tmp
cp -pr *log* $SDC_UPGRADE_DIR

[[ "$CONFIG_capi_is_local" == "true" && -f /var/tmp/capi_access ]] && \
    cp /var/tmp/capi_access $SDC_UPGRADE_DIR
cp -pr $ROOT/upgrade_hooks.sh $SDC_UPGRADE_DIR
chmod +x $SDC_UPGRADE_DIR/upgrade_hooks.sh

echo "$(date -u "+%Y%m%dT%H%M%S") 6.5 done" >>$SDC_UPGRADE_DIR/upgrade_time
mv $SDC_UPGRADE_DIR /var/upgrade_headnode

trap EXIT

echo "Rebooting to finish the upgrade"
echo "    Upgrade progress will be visible on the console or by watching"
echo "    the file /tmp/upgrade_progress after the system reboots."
(sleep 1 && reboot)&
exit 0
