#!/bin/ksh
#set -xv
#####################################################################################
#
# Script Name:
#  tsm_db2backup.ksh
#
# Purpose:
#       Performs a backup of a db2 database using either or a combination of Tivoli
#       Storage Manager and/or Tivoli Storage FlashCopy Manager.
#
# Dependencies:
#       Tivoli FlashCopy Manager must be configured for FlashCopy and/or offloaded
#       Backups and Tivoli Storage Manager must be configured for online or offline
#       backups.
#
# Modification History:
#  v1.0 - 27/10/2015 - Initial Version - Talor (Advent One)
#  v1.1 - 10/11/2015 - Added Lock Function - Talor (Advent One)
#
# Called by:
#  root crontab
#
#####################################################################################

ALERTS=talor@adventone.com
REPORTS=talor@adventone.com
TAG=$(date '+%Y%m%d-%H%M')
LOGDIR=/var/log/tsm
TMPERR=/tmp/.$(basename $0).err.$$
TMPBKP=/tmp/.$(basename $0).bkp.$$
WEEKDAY=$(date +%u)
SCRIPTNAME=${0##*/}
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

usage()
{
        MESSAGE=$*
        echo
        echo "$MESSAGE"
        echo
        echo "$0 -t [online|offline|flashcopy|offload] [-n <# sessions>] [-s <SID>]"
        echo
        exit 1
}

generate_lock()
{
        if [[ -f ${LOCKFILE} ]] ; then
                Pid=$(cat $LOCKFILE)
                if ps -fp $Pid > /dev/null 2>&1 ; then
                        MSG="$SCRIPTNAME [ Pid: $Pid ] already running on ${SID} please investigate"
                        cat $LOG | mailx -s "$MSG" $ALERTS
                        exit
                else
                        rm -rf $LOCKFILE
                        print $$ > ${LOCKFILE}
                fi
        else
                print $$ > ${LOCKFILE}
        fi
}

atexit()
# exit routine
{
        if [ $RV -gt 0 ]
        then
                # Log an after hours ticket if this is production
                if [ $(echo $SID |cut -c 3) = P ]
                then
                        MSG="An error occurred whilst performing a ${TYPE} DATABASE BACKUP of ${SID} on ${HOST}"
                        cat $LOG | mailx -s "$MSG" $ALERTS
                else
                        MSG="An error occurred whilst performing a ${TYPE} DATABASE BACKUP of ${SID} on ${HOST}"
                        cat $LOG | mailx -s "$MSG" $ALERTS
                fi
        else
                MSG="An ${TYPE} database backup of ${SID} on ${HOST} completed successfully"
                cat $LOG |mail -s "$MSG" $REPORTS
        fi

        rm -f $TMPERR >/dev/null
        rm -f $TMPBKP >/dev/null

        # Make sure the lock file is removed
        if [ -f $LOCKFILE ]
        then
                rm -f $LOCKFILE
        fi

        # recycle log files
        if [ -f $LOG ]
        then
                cp -p $LOG $LOG.$TAG
                compress $LOG.$TAG
        fi

        # remove old logs
        /usr/bin/find ${LOGDIR} -name "*${LOG}*" -type f -mtime +60 ! -name "*hardened*" |xargs -n1 /bin/rm -f 1>/dev/null

        msg "The return value is $RV"
        msg Exiting

        exit $RV
}

run_online()
{
        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} started at $(date)"
        echo
        echo "================================================================"
        su - ${DB2USR} -c "/usr/tivoli/tsm/tdp_r3/db264/backom -c b_db -a ${SID} -O -S ${SESSIONS} -e /db2/{$SID}/tdp_r3/init${SID}.utl -v"
        rv=$?
        if [ $rv -eq 0 ]
        then
                ok
        else
                failed
                err "Return value is $rv"
                ((RV=RV+rv))
        fi
        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} ended at $(date)"
        echo
        echo "================================================================"
}

run_offline()
{
        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} started at $(date)"
        echo
        echo "================================================================"

        # Stop SAP and DB2
        msg "Stopping SAP"
        su - ${ADMUSR} -c "stopsap"

        # Force DB2 stop
        msg "Stop DB2 with force option"
        su - ${DB2USR} -c "db2stop force"

        # Start DB2
        msg "Starting DB2"
        su - ${DB2USR} -c "db2start"

        msg "Running the Offline Backup"
        su - ${DB2USR} -c "/usr/tivoli/tsm/tdp_r3/db264/backom -c b_db -a ${SID} -S ${SESSIONS} -e /db2/{$SID}/tdp_r3/init${SID}.utl -v"
        rv=$?
        if [ $rv -eq 0 ]
        then
                 ok
        else
                 failed
                 err "Return value is $rv"
                 ((RV=RV+rv))
        fi

        # Stop DB2
        msg "Stopping DB2"
        su - ${DB2USR} -c "db2stop"

        msg "Starting SAP and DB2"
        # Start SAP and DB2
        echo "Start DB2 & SAP"
        su - ${ADMUSR} -c "startsap"

        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} ended at $(date)"
        echo
        echo "================================================================"
}

run_flashcopy()
{
        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} started at $(date)"
        echo
        echo "================================================================"

        su - ${DB2USR} -c "db2 backup $SID online use snapshot"
        rv=$?
        if [ $rv -eq 0 ]
        then
                ok
        else
                failed
                err "Return value is $rv"
                ((RV=RV+rv))
        fi

        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} ended at $(date)"
        echo
        echo "================================================================"
}

run_offload()
{
        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} started at $(date)"
        echo
        echo "================================================================"

        su - ${DB2USR} -c "/db2/${SID}/sqllib/acs/tsm4acs -f tape_backup"
        rv=$?
        if [ $rv -eq 0 ]
        then
                ok
        else
                failed
                err "Return value is $rv"
                ((RV=RV+rv))
        fi

        echo "================================================================"
        echo
        echo "$TYPE backup of ${SID} ended at $(date)"
        echo
        echo "================================================================"
}

#####################################################################################
###################  Main (Main MAIN Main)
#####################################################################################

# Process options have been passed to the script
while getopts "t:n:s:" opt
do
        case $opt in
                t)      TYPE=${OPTARG} ;;
                n)      SESSIONS=${OPTARG} ;;
                s)      SID=${OPTARG} ;;
                *)      usage "ERROR: Unknown Option"; exit ;;
        esac
done

[ -z "$TYPE" ] && usage "ERROR: Specify the backup type"
[ -z "$SESSIONS" ] && SESSIONS=2 # Use 2 sessoins if nothing specified
[ -z "$SID" ] && usage "ERROR: Specify the SAP SID you want to protect"

MYUSER=`whoami`
if [ $MYUSER != root ]
then
        echo "\nThis script must run as the root user\n"
        RV=111
        exit
fi

DB2USR=db2$(echo $SID | tr 'A-Z' 'a-z')
ADMUSR=$(echo $SID | tr 'A-Z' 'a-z')adm
SID=$(echo $SID | tr 'a-z' 'A-Z')

LOCKFILE=/tmp/.$(basename $0).lck.${SID}
LOG=${LOGDIR}/tsm_db2backup.${SID}.log

generate_lock

# redirect stdout and stderr to the log file
exec >$LOG 2>&1

# Call function at the end if the script exists cleanly.
trap atexit 0

case $TYPE in
        ONLINE|Online|online)
                msg "Running an online db2 database backup to Tivoli Storage Manager"
                run_online
        ;;
        OFFLINE|Offline|offline)
                msg "Running an offline db2 database backup to Tivoli Storage Manager"
                run_offline
        ;;
        FLASHCOPY|Flashcopy|FlashCopy|flashcopy)
                msg "Running FlashCopy only db2 database backup"
                run_flashcopy
        ;;
        OFFLOAD|Offload|offload)
                msg "Running FlashCopy backup of db2 then offloading to Tivoli Storage Manager"
                run_flashcopy
                run_offload
        ;;
        *)
                usage "ERROR Unknown Backup Type"
        ;;
esac

# If script ends with RV=0 then atexit() is called due to trap.
