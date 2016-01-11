#!/bin/ksh
#set -xv
#####################################################################################
#
# Script Name:
#  protect_tsm.ksh
#
# Purpose:
#	Performs TSM aka Spectrum Protect maintenance tasks such as storage pool 
#       protection, node replication and database backup. The storage pools that
#	will be protected must not start with "COPY" as pools with that name are
#	intended to be replica pools from anotehr TSM server and therefore not 
#       protected. The script will then replicate the metadata of all nodes that have
#       replication enabled.
#
# Dependencies:
#	It must be run on a working TSM server, and the TSM ID / Password that the
#	script uses must be defined on the TSM server. The TSM server must already
#       be configured for replication this script will simply run the tasks to
#	replicate the data itself in container pools and the node metadata.
#	If the script is backing up to a file device class it assumed that it is on
#       storage that is seperate to where the TSM database resides and is ideally
#	replicated in some way outside of TSM. The same applies to the prepare file.
#
# Modification History:
#  v1.0 - 07/12/2015 - Initial Version - Talor (Advent One)
#
# Called by:
#  root crontab or by the TSM client scheduler (via define clientaction)
#
#####################################################################################

TSMID="blahblah"
TSMPA="blahblah"
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
        $MSGS && echo $.....
}

msg70()
{
        $MSGS && printf %-70s $......
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
                cat $LOG | mails -s "$MSG" $ALERTS
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
	dsmq "select stgpool_name from stgpools where stg_type='DIRECTORY'"
	do
		msg Running Protect Storage Pool for $STGPOOL
		dsmq "protect stgpool $STGPOOL maxsessions=${SESSIONS} purgedata=deleted wait=yes
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
	for node in $(dsmq "select node_name from nodes where repl_state='ENABLED' and repl_mode='SEND'")
	do
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
	dsmq "backup database type=full devc=${DEVCLASS} numstreams=4 wait=yes"
	if [ $rv -eq 0 ]
	then
		ok
	else
		failed
		err "Return value is $rv"
		((RV=RV+rv))
	fi
}

drm_prepare()
{
        dsmq "backup devconfig" 1>/dev/null
        dsmq "backup volhist" 1>/dev/null
        dsmq "prepare wait=yes" 1>/dev/null
}
expire_inv()
{
        dsmq "expire inventory resource=4 wait=yes" 1>/dev/null
        dsmq "del volhist type=dbs tod=-7"
        dsmq "del volhist type=dbb tod=-7"
        dsmq "del volhist type=stgdelete tod=today-35"
        dsmq "del volhist type=stgreuse tod=today-35"
        dsmq "del volhist type=stgnew tod=today-35"
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

[ -z $SESSIONS ] && SESSIONS=8 # Use 8 sessions if nothing specified
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

msg Starting a full TSM database backup
protect_database

msg "Generating Disaster recovery information"
drm_prepare

msg Running TSM Inventory Expiration
expire_inv

# If script ends with RV=0 then atexit() is called due to trap.
