#!/bin/ksh
#set -xv
######################################################################
#
# Script Name    : tsm_jfs2backup.ksh
#
# Purpose        : Takes a JFS2 Snapshot Backup to TSM
# Note           : Sends an email to the backup administrator on failure
# Called by      : root cron
# Author         : Talor Holloway (Advent One)
# Date           : 05/09/2013
######################################################################
# global variables
TOUSER=talor.holloway@adventone.com
DAYOFMONTH=`date +%d`
TMPERR=/tmp/.$(basename $0).err.$$
WEEKDAY=$(date +%u)
TAG=$(date '+%Y%m%d-%H%M')
LOGDIR=/var/log/tsm
LOG=${LOGDIR}/tsm_jfs2backup.log
HOST=$(echo `hostname` | tr 'a-z' 'A-Z')
EXCLUDEVG=backupvg
LVPP=16 # Number of LPs to use for each Snapshot LV
MSGS=true
ERRS=true
RV=0

# functions
msg()
{
        $MSGS && echo "$*....."
}

err()
{
        $ERRS && echo "$*....." >&2
}

ok()
{
        $MSGS && echo ok
}

failed()
{
        $MSGS && echo failed
}

atexit()
# exit routine
{
        # recycle log files
        if [ -f $LOG ]
        then
                cp -p $LOG $LOG.$WEEKDAY
                if [ -f $LOG.$WEEKDAY.Z ]
                then
                        rm -f $LOG.$WEEKDAY.Z
                fi
                compress $LOG.$WEEKDAY
        fi

        if [ $RV -gt 0 ]
        then
                cat $LOG | mail -s "The JFS2 Snapshot Backup on $HOST has Failed" $TOUSER
                echo $RV
                rm -f $TMPERR 2>/dev/null
                msg "Exiting"
        fi
}

# main MAIN Main

trap "atexit" 0

# redirect stdout and stderr
exec >$LOG 2>&1

msg a JFS2 Snapshot will be created and backed up to TSM for the below Filesystems

for VG in `lsvg -o |grep -v rootvg`
do
        lsvgfs $VG |sort -n
done

msg Checking the Filesystems are JFS2

for VG in `lsvg -o |grep -v rootvg |egrep -v ${EXCLUDEVG}`
do
        for FS in `lsvgfs $VG |sort -n`
        do
                FSTYPE=`lsfs $FS |grep $FS |awk '{print $4}'`
                if [ $FSTYPE = "jfs2" ]
                then
                        msg $FS is $FSTYPE Continuing
                        ok
                else
                        $FS is $FSTYPE not jfs2
                        failed
                        msg Exiting
                        exit 1
                fi
        done
done

msg Checking for Sufficent partition space for snapshot creation

for VG in `lsvg -o |grep -v rootvg |egrep -v ${EXCLUDEVG}`
do
        FREEPP=`lsvg $VG |grep 'FREE PPs' |awk '{print $6}'`
        NUMSNAP=`lsvgfs $VG |wc -l`
        if [ $(($NUMSNAP * $LVPP)) -gt $FREEPP ]
        then
                msg There are not enough Free PPs in $VG to create the snapshots
                failed
                exit 1
        else
                msg There are sufficent PPs in $VG to create the snapshots
                ok
        fi
done

msg Checking the directory for mounting exists

for VG in `lsvg -o |grep -v rootvg |egrep -v ${EXCLUDEVG}`
do
        for FS in `lsvgfs $VG |sort -n`
        do
                if [ -d /mnt${FS} ]
                then
                        msg Snapshot Mount for $FS Exists Continuing
                else
                        msg Snapshot Mount for $FS Non-Existing Creating
                        mkdir /mnt${FS}
                fi
        done
done

msg Creating the JFS2 Snapshots

for VG in `lsvg -o |grep -v rootvg |egrep -v ${EXCLUDEVG}`
do
        for FS in `lsvgfs $VG |sort -n`
        do
                LV=`df -g $FS | grep $FS |awk '{print $1}' |cut -c 6-100`

                msg Creating snp${LV}
                mklv -y snp${LV} -t jfs2 $VG 1 >/dev/null
                rv=$?
                if [ $rv -eq 0 ]
                then
                        ok
                else
                        failed
                        err "Return value is $rv"
                        ((RV=RV+rv))
                fi

                msg Creating JFS2 snapshot of $FS to /dev/snp${LV}
                snapshot -o snapfrom=$FS /dev/snp${LV}
                rv=$?
                if [ $rv -eq 0 ]
                then
                        ok
                else
                        failed
                        err "Return value is $rv"
                        ((RV=RV+rv))
                fi

                msg Mounting JFS2 Snapshot of $FS on /mnt${FS}
                mount -v jfs2 -o snapshot /dev/snp${LV} /mnt${FS}
                rv=$?
                if [ $rv -eq 0 ]
                then
                        ok
                df -g /mnt${FS}
                else
                        failed
                        err "Return value is $rv"
                        ((RV=RV+rv))
                fi
        done
done

msg Backing up the JFS2 Snapshots to Tivoli Storage Manager

for VG in `lsvg -o |grep -v rootvg |egrep -v ${EXCLUDEVG}`
do
        for FS in `lsvgfs $VG |sort -n`
        do
                if [ $DAYOFMONTH = "1" ]
                then
                        dsmc incr "${FS}/*" -snapshotroot=/mnt${FS} -asnode=${HOST}_MLY -subdir=yes
                        rv=$?
                        if [ $rv -eq 0 ]
                        then
                                ok
                        else
                                failed
                                err "Return value is $rv"
                                ((RV=RV+rv))
                        fi
                else
                        dsmc incr "${FS}/*" -snapshotroot=/mnt${FS} -subdir=yes
                        rv=$?
                        if [ $rv -eq 0 ]
                        then
                                ok
                        else
                                failed
                                err "Return value is $rv"
                                ((RV=RV+rv))
                        fi
                fi
        done
done

msg Unmounting the Snapshots

for VG in `lsvg -o |grep -v rootvg`
do
        for FS in `lsvgfs $VG |sort -n`
        do
                msg Unmounting /mnt${FS}
                umount /mnt${FS}
                rv=$?
                if [ $rv -eq 0 ]
                then
                        ok
                else
                        failed
                        err "Return value is $rv"
                        ((RV=RV+rv))
                fi
        done
done

msg Deleting the JFS2 Snapshots

for VG in `lsvg -o |grep -v rootvg`
do
        for FS in `lsvgfs $VG |sort -n`
        do
                for SNAPSHOT in `snapshot -q $FS |grep '/dev/' |awk '{print $2}'`
                do
                        msg Deleting the below snapshot for $FS
                        snapshot -q $FS
                        snapshot -d $SNAPSHOT >/dev/null
                        rv=$?
                        if [ $rv -eq 0 ]
                        then
                                ok
                        else
                                failed
                                err "Return value is $rv"
                                ((RV=RV+rv))
                        fi
                done
        done
done

# If script ends with RC=0 then atexit() is called due to trap.
