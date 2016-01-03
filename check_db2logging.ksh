#!/bin/ksh
#set -xv
#####################################################################################
#
# Script Name:
#  check_db2logging.ksh
#
# Purpose:
#  This script will report on the DB2 archive log backup status for each SAP SID on
#  an AIX LPAR that contains functional SAP systems using a by a DB2 database.
#
# Dependencies:
#  The nagios npre agent must be installed and functioning. The db2diag.log needs
#  to exist in  /db2/<SID>/db2dump/db2diag.log.
#
# Modification History:
#  v1.0 - 29/10/2015 - Initial Version - Talor (Advent One)
#
# Called by:
#  Nagios nrpe agent
#
#####################################################################################
RV=0
NORM_EXIT_CODE=0
WARN_EXIT_CODE=1
CRIT_EXIT_CODE=2
MSGS=true
ERRS=true
TODAY=$(date '+%Y%m%d')
SCRIPTNAME=${0##*/}
LOCKFILE=/tmp/.$(basename $0).lck.$$

#####################################################################################
###################  Functions
#####################################################################################

atexit()
# exit routine
{
    # Make sure the lock file is removed
    if [ -f $LOCKFILE ]
    then
            rm -f $LOCKFILE
    fi

    exit $RV
}

msg()
{
        $MSGS && echo "$*....."
}

generate_lock()
{
        if [[ -a ${LOCKFILE} ]] ; then
                Pid=$(cat $LOCKFILE)
                if ps -fp $Pid > /dev/null 2>&1 ; then
                        echo "$SCRIPTNAME [ Pid: $Pid ] already running, please investigate"
                        RV=$WARN_EXIT_CODE
                        exit
                else
                        rm -rf $LOCKFILE
                        print $$ > ${LOCKFILE}
                fi
        else
                print $$ > ${LOCKFILE}
        fi
}

check_db2_logging()
{
        SID=$1
        sid=$(echo $SID |tr 'A-Z' 'a-z')
        DB2DIAG=/db2/${SID}/db2dump/db2diag.log

        if [ -f $DB2DIAG ]
        then
                if [ $(tail -100 $DB2DIAG |egrep -c 'ADM1848W|"Failed archive for log file"|"Failed to archive log file"') -gt 0 ]
                then
                        if [ $(echo $SID |cut -c 3) = P ]
                        then
                                BADSID=$(echo $BADSID $SID)
                                RV=$CRIT_EXIT_CODE
                        else
                                BADSID=$(echo $BADSID $SID)
                                RV=$WARN_EXIT_CODE
                        fi
                fi
        fi
}

#####################################################################################
###################  Main (Main MAIN Main)
#####################################################################################

# Call function at the end if the script exists cleanly.
trap "atexit" 0

generate_lock

for sid in `cat /usr/sap/sapservices | awk '{ print $8 }' | sort -u | cut -c1-3 |grep -v "^$"`
do
        SID=`echo $sid | cut -c1-3 | tr 'a-z' 'A-Z'`
        check_db2_logging $SID
done

if [ $RV -gt 0 ]
then
        msg "Archive logging to TSM on ${BADSID} is not working on $(hostname)"
else
        msg "No issues detected with the archive logging for the SAP system(s) on $(hostname)"
fi

# If script ends with RV=0 then atexit() is called due to trap.