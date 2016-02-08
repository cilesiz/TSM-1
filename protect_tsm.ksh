#!/bin/ksh
#set -xv
#####################################################################################
#
# Script Name:
#       protect_tsm.ksh
#
# Purpose:
#       Performs TSM aka Spectrum Protect maintenance tasks such as storage pool
#       protection, node replication and database backup. The storage pools that
#       will be protected must not start with "COPY" as pools with that name are
#       intended to be replica pools from anotehr TSM server and therefore not
#       protected. The script will then replicate the metadata of all nodes that have
#       replication enabled.
#
# Dependencies:
#       It must be run on a working TSM server, and the TSM ID / Password that the
#       script uses must be defined on the TSM server. The TSM server must already
#       be configured for replication this script will simply run the tasks to
#       replicate the data itself in container pools and the node metadata.
#       If the script is backing up to a file device class it assumed that it is on
#       storage that is seperate to where the TSM database resides and is ideally
#       replicated. There is a function to rsync to a remote TSM server however SSH
#       keys and the directory structure must exist on the remote TSM server.
#
# Modification History:
#       v1.0 - 07/12/2015 - Initial Version - Talor (Advent One)
#	v1.1 - 02/02/2015 - Added rsync_remote function - TH
#
# Called by:
#       root crontab or by the TSM client scheduler (via define clientaction)
#
#####################################################################################

TSMPA="xxx"
TSMID="xxx"
ALERTS=talor@adventone.com
TAG=$(date '+%Y%m%d-%H%M')
LOGDIR=/var/log/tsm
LOG=${LOGDIR}/protect_tsm.log
SCRIPTNAME=${0##}
LOCKFILE=/tmp/.$(basename $0).lck
WEEKDAY=$(date +%u)
TAG=$(date '+%Y%m%d-%H%M')
HOST=$(echo `hostname` | tr 'a-z' 'A-Z')
MSGS=true
ERRS=true
RV=0

#####################################################################################
###################  Functions
#####################################################################################

msg()
{
        $MSGS && echo "$*....."
}

msg70()
{
# like msg but doesn't print a new line instead just stops at 70th column {
        $MSGS && printf "%-70s" "$*......"
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

dsmq()
{
 dsmadmc -id=${TSMID} -pa=${TSMPA} -dataonly=yes -noconfirm "$*"
 rv=$?
}

usage()
{
        MESSAGE=$*
        echo
        echo "$MESSAGE"
        echo
        echo "$0 -d [devclass for DB backup] [-n <# replication sessions>]"
        RV=1
        exit
}

atexit()
# exit routine
{
        if [ $RV -gt 0 ]
        then
                MSG="$HOST: An error occurred whilst performaing maintenance tasks"
                cat $LOG | mailx -s "$MSG" $ALERTS
        fi

        # Make sure the lock file is removed
        if [ -f $LOCKFILE ]
        then
                rm -f $LOCKFILE
        fi

        # recycle log files
        if [ -f $LOG ]
        then
                cp $LOG $LOG.$WEEKDAY
                if [ -f $LOG.$WEEKDAY.Z ]
                then
                        rm $LOG.$WEEKDAY.Z
                fi
                compress $LOG.$WEEKDAY
        fi

        msg The return value is $RV
        msg Exiting

        exit $RV
}

generate_lock()
{
        if [[ -a ${LOCKFILE} ]] ; then
                echo Lock $LOCKFILE already exists, checking UNIX process
                Pid=$(cat $LOCKFILE)
                if ps -fp $Pid > /dev/null 2>&1 ; then
                        echo $SCRIPTNAME [ Pid $Pid ] already running, please investigate
                        RV=666
                        exit
                else
                        echo Abandoned lock $LOCKFILE for $SCRIPTNAME [ Pid $Pid ], releasing lock
                        rm -rf $LOCKFILE
                        echo Writing lock $LOCKFILE for $SCRIPTNAME [ Pid $$ ]
                        print $$ > ${LOCKFILE}
                fi
        else
                echo Writing Lock $LOCKFILE for $SCRIPTNAME [ Pid $$ ]
                print $$ > ${LOCKFILE}
        fi
}

protect_stgpools()
{
        for STGPOOL in $(dsmq "select stgpool_name from stgpools where stg_type='DIRECTORY'")
        do
                msg70 Running Protect Storage Pool for $STGPOOL
                dsmq "protect stgpool $STGPOOL maxsessions=${SESSIONS} purgedata=deleted wait=yes" 1>/dev/null
                if [ $rv -eq 0 ]
                then
                        ok
                else
                        failed
                        err "Return value is $rv"
                        ((RV=RV+rv))
                fi
        done
}

protect_nodes()
{
        for NODE in $(dsmq "select node_name from nodes where repl_state='ENABLED' and repl_mode='SEND'")
        do
                msg70 "Replicating $NODE"
                dsmq "replicate node $NODE maxsessions=${SESSIONS} wait=yes FORCEREConcile=yes" 1>/dev/null
                if [ $rv -eq 0 ]
                then
                        ok
                else
                        failed
                        err "Return value is $rv"
                        ((RV=RV+rv))
                fi
        done
}

protect_database()
{
        dsmq "backup db type=full devc=${DEVCLASS} numstreams=4 wait=yes" 1>/dev/null
        if [ $rv -eq 0 ]
        then
                ok
        else
                failed
                err "Return value is $rv"
                ((RV=RV+rv))
        fi
}

expire_inv()
{
        dsmq "expire inventory resource=4 wait=yes" 1>/dev/null
        ok
        msg70 "Running volume history pruning"
        dsmq "del volhist type=dbs tod=-4" 1>/dev/null
        dsmq "del volhist type=dbb tod=-4" 1>/dev/null
        dsmq "del volhist type=stgdelete tod=today-35" 1>/dev/null
        dsmq "del volhist type=stgreuse tod=today-35" 1>/dev/null
        dsmq "del volhist type=stgnew tod=today-35" 1>/dev/null
        ok

        DBBDIRECTORY=$(dsmadmc -id=${TSMID} -pa=${TSMPA} -dataonly=yes -comma "select devclass_name, directory from devclasses" |grep $(echo $DEVCLASS |tr 'a-z' 'A-Z') |awk -F, '{print $2}')
        msg70 Deleting old DB Backup files from $DBBDIRECTORY
        /usr/bin/find ${DBBDIRECTORY} -name "*.dss" -type f -mtime +5 ! -name "*hardened*" |xargs -n1 /bin/rm -f 1>/dev/null 2>&1
        /usr/bin/find ${DBBDIRECTORY} -name "*.dbv" -type f -mtime +5 ! -name "*hardened*" |xargs -n1 /bin/rm -f 1>/dev/null 2>&1
        ok
}

rsync_remote()
{
        REMOTE_TSM=$(dsmq "select TARGET_REPL_SERVER_NAME from STATUS" |tr 'A-Z' 'a-z' |awk '{print $1}')
        DBBDIRECTORY=$(dsmadmc -id=${TSMID} -pa=${TSMPA} -dataonly=yes -comma "select devclass_name, directory from devclasses" |grep $(echo $DEVCLASS |tr 'a-z' 'A-Z') |awk -F, '{print $2}')

        if [ ! -d ${DBBDIRECTORY}/config ]
        then
                mkdir -p ${DBBDIRECTORY}/config
        fi

        msg70 Copying Files
        PLANPREFIX=$(dsmq "select PLANPREFIX from DRMSTATUS" |awk '{print $1}')
        cp -pr ${PLANPREFIX}* ${DBBDIRECTORY}/config/
        cp -p $(dsmadmc -id=${TSMID} -pa=${TSMPA} -dataonly=yes -comma "select OPTION_VALUE from OPTIONS where OPTION_NAME='Devconfig'" |head -1) ${DBBDIRECTORY}/config/
        cp -p $(dsmadmc -id=${TSMID} -pa=${TSMPA} -dataonly=yes -comma "select OPTION_VALUE from OPTIONS where OPTION_NAME='VolumeHistory'" |head -1) ${DBBDIRECTORY}/config/
        ok

        msg70 Attempting rsync copy of database backups to ${REMOTE_TSM}
        ssh -o 'StrictHostKeyChecking=no'-q ${REMOTE_TSM} "date" 1>/dev/null 2>/dev/null
        rv=$?
        if [ $rv -eq 0 ]
        then
                rsync -a --super --delete ${DBBDIRECTORY} ${DBBDIRECTORY} 1>/dev/null
                if [ $rv -eq 0 ]
                then
                        ok
                else
                        failed
                        err "Return value is $rv"
                        ((RV=RV+rv))
                fi
        else
                failed
                err "Could not connect to ${REMOTE_TSM} over SSH"
                err "Return value is $rv"
                ((RV=RV+rv))
        fi
}

#####################################################################################
###################  Main (Main MAIN Main)
#####################################################################################

# redirect stdout and stderr to the log file
exec >$LOG 2>&1

# Call function at the end if the script exists cleanly.
trap atexit 0

# Process options have been passed to the script
while getopts :d:n: opt
do
        case $opt in
                d)      DEVCLASS=${OPTARG} ;;
                n)      SESSIONS=${OPTARG} ;;
                *)      usage ERROR Unknown Option; exit ;;
        esac
done

[ -z "$SESSIONS" ] && SESSIONS=8 # Use 8 sessions if nothing specified
[ -z "$DEVCLASS" ] && usage "ERROR: Device Class for TSM Database Backup"

MYUSER=`whoami`
if [ $MYUSER != root ]
then
        msg This script must run as the root user
        echo "\n"
        RV=111
        exit
fi

# Generate the lock
generate_lock

msg Starting storage pool protection with $SESSIONS per storage pool
protect_stgpools

msg Starting node replication four nodes at a time with $SESSIONS sessions per node
protect_nodes

msg70 Starting a full TSM database backup
protect_database

msg70 Running TSM Inventory Expiration
expire_inv

msg Taking a copy of tsm critical files and attempting rsync copy of critical files to a remote TSM server
rsync_remote

# If script ends with RV=0 then atexit() is called due to trap.
