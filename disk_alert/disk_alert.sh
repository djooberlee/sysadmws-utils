#!/bin/bash

# Set vars
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [[ "$LANG" != "en_US.UTF-8" ]]; then export LANG=C ; fi
DATE=$(date '+%F %T')
declare -A DISK_ALERT_PERCENT_CRITICAL
declare -A DISK_ALERT_PERCENT_WARNING
declare -A DISK_ALERT_FREE_SPACE_CRITICAL
declare -A DISK_ALERT_FREE_SPACE_WARNING
declare -A DISK_ALERT_PREDICT_CRITICAL
declare -A DISK_ALERT_PREDICT_WARNING
declare -A DISK_ALERT_INODE_CRITICAL
declare -A DISK_ALERT_INODE_WARNING
# Seconds since unix epoch
TIMESTAMP=$(date '+%s')

# Severity codes for victoria metrics
severity_ok='0'
severity_indeterminate='1'
severity_informational='2'
severity_warning='3'
severity_minor='4'
severity_major='5'
severity_critical='6'
severity_fatal='7'
severity_security='8'

# Function to send disk metric to victoria metrics
function send_disk_metric_to_victoria {
	if [[ -z "${VMAGENT_URL}" ]] || [[ -z "${1}" ]] || [[ -z "${2}" ]] ; then
		echo "Error: 'send_disk_metric_to_victoria' missing arguments or 'VMAGENT_URL' is not set in 'disk_alert.conf'"
		echo "Usage: send_disk_metric_to_victoria <metric_name> <metric_value>"
		return 1
	fi
	local timestamp=$(date +%s000)
	local METRIC_NAME=$1
	local METRIC_VALUE=$2
	curl ${VMUSER:+${VMUSER_PWD:+-u "$VMUSER:$VMUSER_PWD"}} -d @- -X POST "${VMAGENT_URL}/api/v1/import" <<EOF
{
	"metric": {
	"__name__":  "${METRIC_NAME}",
	"host":      "${HOSTNAME}",
	"partition": "${PARTITION}"
	},
	"values":    [${METRIC_VALUE}],
	timestamps": [${timestamp}]
}
EOF
}

# Include config
if [ -f /opt/sysadmws/disk_alert/disk_alert.conf ]; then
	. /opt/sysadmws/disk_alert/disk_alert.conf
fi

# Optional first arg - random sleep up to arg value
if [[ -n "$1" ]]; then
	sleep $((RANDOM % $1))
fi

# Check defaults
if [[ -n "${HOSTNAME_OVERRIDE}" ]]; then
	HOSTNAME=${HOSTNAME_OVERRIDE}
else
	HOSTNAME=$(hostname -f)
fi
#
if [[ _$DISK_ALERT_FILTER != "_" ]]; then
	FILTER=$DISK_ALERT_FILTER
else
	FILTER="^Filesystem|^tmpfs|^cdrom|^none|^/dev/loop|^overlay|^shm|^udev|^cgroup|^cgmfs|^snapfuse|kubernetes.io|volume-subpaths|/var/lib/incus/storage-pools"
fi
#
if [[ _$DISK_ALERT_USAGE_CHECK == "_PERCENT" ]]; then
	USAGE_CHECK="PERCENT"
elif [[ _$DISK_ALERT_USAGE_CHECK == "_FREE_SPACE" ]]; then
	USAGE_CHECK="FREE_SPACE"
else
	USAGE_CHECK="PERCENT"
fi
#
if [[ _$DISK_ALERT_HISTORY_SIZE != "_" ]]; then
	HISTORY_SIZE=$DISK_ALERT_HISTORY_SIZE
else
	HISTORY_SIZE="2016"
fi

# Make history dir
mkdir -p "/opt/sysadmws/disk_alert/history"

# Check df space
df -P -BM | grep -vE $FILTER | awk '{ print $5 " " $6 " " $4 }' | while read output; do
	USEP=$(echo $output | awk '{ print $1}' | cut -d'%' -f1 )
	PARTITION=$(echo $output | awk '{ print $2 }' )
	FREESP=$(echo $output | awk '{ print $3}' | sed 's/.$//' )
	# Get thresholds
	if [[ _${DISK_ALERT_PERCENT_CRITICAL[$PARTITION]} != "_" ]]; then
		CRITICAL=${DISK_ALERT_PERCENT_CRITICAL[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_PERCENT_CRITICAL != "_" ]]; then
		CRITICAL=$DISK_ALERT_DEFAULT_PERCENT_CRITICAL
	else
		CRITICAL="95"
	fi
	if [[ _${DISK_ALERT_PERCENT_WARNING[$PARTITION]} != "_" ]]; then
		WARNING=${DISK_ALERT_PERCENT_WARNING[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_PERCENT_WARNING != "_" ]]; then
		WARNING=$DISK_ALERT_DEFAULT_PERCENT_WARNING
	else
		WARNING="90"
	fi
	#
	if [[ _${DISK_ALERT_FREE_SPACE_CRITICAL[$PARTITION]} != "_" ]]; then
		FREE_SPACE_CRITICAL=${DISK_ALERT_FREE_SPACE_CRITICAL[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_FREE_SPACE_CRITICAL != "_" ]]; then
		FREE_SPACE_CRITICAL=$DISK_ALERT_DEFAULT_FREE_SPACE_CRITICAL
	else
		FREE_SPACE_CRITICAL="1024"
	fi
	if [[ _${DISK_ALERT_FREE_SPACE_WARNING[$PARTITION]} != "_" ]]; then
		FREE_SPACE_WARNING=${DISK_ALERT_FREE_SPACE_WARNING[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_FREE_SPACE_WARNING != "_" ]]; then
		FREE_SPACE_WARNING=$DISK_ALERT_DEFAULT_FREE_SPACE_WARNING
	else
		FREE_SPACE_WARNING="2048"
	fi
	#
	if [[ _${DISK_ALERT_PREDICT_CRITICAL[$PARTITION]} != "_" ]]; then
		PREDICT_CRITICAL=${DISK_ALERT_PREDICT_CRITICAL[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_PREDICT_CRITICAL != "_" ]]; then
		PREDICT_CRITICAL=$DISK_ALERT_DEFAULT_PREDICT_CRITICAL
	else
		PREDICT_CRITICAL="3600"
	fi
	if [[ _${DISK_ALERT_PREDICT_WARNING[$PARTITION]} != "_" ]]; then
		PREDICT_WARNING=${DISK_ALERT_PREDICT_WARNING[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_PREDICT_WARNING != "_" ]]; then
		PREDICT_WARNING=$DISK_ALERT_DEFAULT_PREDICT_WARNING
	else
		PREDICT_WARNING="86400"
	fi
	# Usage check type
	if [[ $USAGE_CHECK == "PERCENT" ]]; then
		# 100% is always fatal
		if [[ $USEP -eq "100" ]]; then
			echo '{
				"severity": "fatal",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_high",
				"origin": "disk_alert.sh",
				"text": "Disk usage fatal percentage detected",
				"value": "'$USEP'%",
				"correlate": ["disk_alert_space_usage_ok"],
				"attributes": {
					"free space": "'$FREESP'MB",
					"warning threshold": "'$WARNING'%",
					"critical threshold": "'$CRITICAL'%"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage_severity ${severity_fatal}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage $USEP
			fi
		# Critical percent message
		elif [[ $USEP -ge $CRITICAL ]]; then
			echo '{
				"severity": "critical",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_high",
				"origin": "disk_alert.sh",
				"text": "Disk usage critical percentage detected",
				"value": "'$USEP'%",
				"correlate": ["disk_alert_space_usage_ok"],
				"attributes": {
					"free space": "'$FREESP'MB",
					"warning threshold": "'$WARNING'%",
					"critical threshold": "'$CRITICAL'%"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage_severity ${severity_critical}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage $USEP
			fi
		elif [[ $USEP -ge $WARNING ]]; then
			echo '{
				"severity": "major",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_high",
				"origin": "disk_alert.sh",
				"text": "Disk usage warning percentage detected",
				"value": "'$USEP'%",
				"correlate": ["disk_alert_space_usage_ok"],
				"attributes": {
					"free space": "'$FREESP'MB",
					"warning threshold": "'$WARNING'%",
					"critical threshold": "'$CRITICAL'%"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage_severity ${severity_major}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage $USEP
			fi
		else
			echo '{
				"severity": "ok",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_ok",
				"origin": "disk_alert.sh",
				"text": "Disk usage ok percentage detected",
				"value": "'$USEP'%",
				"correlate": ["disk_alert_space_usage_high"],
				"attributes": {
					"free space": "'$FREESP'MB",
					"warning threshold": "'$WARNING'%",
					"critical threshold": "'$CRITICAL'%"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage_severity ${severity_ok}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_space_usage_percentage $USEP
			fi
		fi
	elif [[ $USAGE_CHECK == "FREE_SPACE" ]]; then
		# 0 is always fatal
		if [[ $FREESP -eq "0" ]]; then
			echo '{
				"severity": "fatal",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_high",
				"origin": "disk_alert.sh",
				"text": "Fatal disk free space in MB detected",
				"value": "'$FREESP'MB",
				"correlate": ["disk_alert_space_usage_ok"],
				"attributes": {
					"use": "'$USEP'%",
					"warning threshold": "'$FREE_SPACE_WARNING'MB",
					"critical threshold": "'$FREE_SPACE_CRITICAL'MB"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb_severity ${severity_fatal}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb $FREESP
			fi
		# Critical free space message
		elif [[ $FREESP -le $FREE_SPACE_CRITICAL ]]; then
			echo '{
				"severity": "critical",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_high",
				"origin": "disk_alert.sh",
				"text": "Critical disk free space in MB detected",
				"value": "'$FREESP'MB",
				"correlate": ["disk_alert_space_usage_ok"],
				"attributes": {
					"use": "'$USEP'%",
					"warning threshold": "'$FREE_SPACE_WARNING'MB",
					"critical threshold": "'$FREE_SPACE_CRITICAL'MB"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb_severity ${severity_critical}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb $FREESP
			fi
		elif [[ $FREESP -le $FREE_SPACE_WARNING ]]; then
			echo '{
				"severity": "major",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_high",
				"origin": "disk_alert.sh",
				"text": "Warning disk free space in MB detected",
				"value": "'$FREESP'MB",
				"correlate": ["disk_alert_space_usage_ok"],
				"attributes": {
					"use": "'$USEP'%",
					"warning threshold": "'$FREE_SPACE_WARNING'MB",
					"critical threshold": "'$FREE_SPACE_CRITICAL'MB"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb_severity ${severity_major}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb $FREESP
			fi
		else
			echo '{
				"severity": "ok",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'",
				"event": "disk_alert_space_usage_ok",
				"origin": "disk_alert.sh",
				"text": "Ok disk free space in MB detected",
				"value": "'$FREESP'MB",
				"correlate": ["disk_alert_space_usage_high"],
				"attributes": {
					"use": "'$USEP'%",
					"warning threshold": "'$FREE_SPACE_WARNING'MB",
					"critical threshold": "'$FREE_SPACE_CRITICAL'MB"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb_severity ${severity_ok}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_free_space_mb $FREESP
			fi
		fi
	fi
	# Add partition usage history by seconds from unix epoch
	PARTITION_FN=$(echo $PARTITION | sed -e 's#/#_#g')
	echo "$TIMESTAMP	$USEP" >> "/opt/sysadmws/disk_alert/history/$PARTITION_FN.txt"
	# Leave only last N lines in file
	tail -n $HISTORY_SIZE "/opt/sysadmws/disk_alert/history/$PARTITION_FN.txt" > "/opt/sysadmws/disk_alert/history/$PARTITION_FN.txt.new"
	mv -f "/opt/sysadmws/disk_alert/history/$PARTITION_FN.txt.new" "/opt/sysadmws/disk_alert/history/$PARTITION_FN.txt"
	# Get linear regression json
	LR=$(awk -f /opt/sysadmws/disk_alert/lr.awk --assign timestamp="$TIMESTAMP" "/opt/sysadmws/disk_alert/history/$PARTITION_FN.txt" 2>/dev/null)
	if [[ _$LR == "_" ]]; then
		P_ANGLE="None"
		P_SHIFT="None"
		P_QUALITY="None"
		PREDICT_SECONDS="None"
		P_HMS="None"
	else
		# Get predict seconds value
		export PYTHONIOENCODING=utf8
                P_ANGLE=$(echo "$LR" | python -c "import sys, json; print(json.load(sys.stdin)['angle'])")
                P_SHIFT=$(echo "$LR" | python -c "import sys, json; print(json.load(sys.stdin)['shift'])")
                P_QUALITY=$(echo "$LR" | python -c "import sys, json; print(json.load(sys.stdin)['quality'])")
                PREDICT_SECONDS=$(echo "$LR" | python -c "import sys, json; print(json.load(sys.stdin)['predict seconds'])")
                P_HMS=$(echo "$LR" | python -c "import sys, json; print(json.load(sys.stdin)['predict hms'])")
	fi
	# Critical predict message
	if [[ $PREDICT_SECONDS != "None" ]]; then
		if [[ $PREDICT_SECONDS -lt $PREDICT_CRITICAL && $PREDICT_SECONDS -gt 0 ]]; then
			echo '{
				"severity": "minor",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'-predict",
				"event": "disk_alert_predict_usage_high",
				"origin": "disk_alert.sh",
				"text": "Full usage of disk predicted within critical threshold",
				"value": "'$PREDICT_SECONDS's",
				"correlate": ["disk_alert_predict_usage_ok"],
				"attributes": {
					"use": "'$USEP'%",
					"free space": "'$FREESP'MB",
					"angle": "'$P_ANGLE'",
					"shift": "'$P_SHIFT'",
					"quality": "'$P_QUALITY'",
					"predict hms": "'$P_HMS'",
					"predict warning threshold": "'$PREDICT_WARNING'",
					"predict critical threshold": "'$PREDICT_CRITICAL'"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_predicted_full_sec_severity ${severity_minor}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_predicted_full_sec $PREDICT_SECONDS
			fi
		elif [[ $PREDICT_SECONDS -lt $PREDICT_WARNING && $PREDICT_SECONDS -gt 0 ]]; then
			echo '{
				"severity": "warning",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'-predict",
				"event": "disk_alert_predict_usage_high",
				"origin": "disk_alert.sh",
				"text": "Full usage of disk predicted within warning threshold",
				"value": "'$PREDICT_SECONDS's",
				"correlate": ["disk_alert_predict_usage_ok"],
				"attributes": {
					"use": "'$USEP'%",
					"free space": "'$FREESP'MB",
					"angle": "'$P_ANGLE'",
					"shift": "'$P_SHIFT'",
					"quality": "'$P_QUALITY'",
					"predict hms": "'$P_HMS'",
					"predict warning threshold": "'$PREDICT_WARNING'",
					"predict critical threshold": "'$PREDICT_CRITICAL'"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_predicted_full_sec_severity ${severity_warning}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_predicted_full_sec $PREDICT_SECONDS
			fi
		else
			echo '{
				"severity": "ok",
				"service": "disk",
				"resource": "'$HOSTNAME':'$PARTITION'-predict",
				"event": "disk_alert_predict_usage_ok",
				"origin": "disk_alert.sh",
				"text": "No full usage of disk predicted within threshold",
				"value": "'$PREDICT_SECONDS's",
				"correlate": ["disk_alert_predict_usage_high"],
				"attributes": {
					"use": "'$USEP'%",
					"free space": "'$FREESP'MB",
					"angle": "'$P_ANGLE'",
					"shift": "'$P_SHIFT'",
					"quality": "'$P_QUALITY'",
					"predict hms": "'$P_HMS'",
					"predict warning threshold": "'$PREDICT_WARNING'",
					"predict critical threshold": "'$PREDICT_CRITICAL'"
				}
			}' | /opt/sysadmws/notify_devilry/notify_devilry.py
			if [[ ! -z "${VMAGENT_URL}" ]]; then
				send_disk_metric_to_victoria microdevops_agent_disk_alert_predicted_full_sec_severity ${severity_ok}
				send_disk_metric_to_victoria microdevops_agent_disk_alert_predicted_full_sec $PREDICT_SECONDS
			fi
		fi
	fi
done

# Check df inodes
df -P -i | grep -vE $FILTER | awk '{ print $5 " " $6 }' | while read output; do
	USEP=$(echo $output | awk '{ print $1}' | cut -d'%' -f1 )
	PARTITION=$(echo $output | awk '{ print $2 }' )
	# Skip partitions without inodes
	if [[ _$USEP = _- ]]; then
		continue
	fi
	# Get thresholds
	if [[ _${DISK_ALERT_INODE_CRITICAL[$PARTITION]} != "_" ]]; then
		CRITICAL=${DISK_ALERT_INODE_CRITICAL[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_INODE_CRITICAL != "_" ]]; then
		CRITICAL=$DISK_ALERT_DEFAULT_INODE_CRITICAL
	else
		CRITICAL="95"
	fi
	if [[ _${DISK_ALERT_INODE_WARNING[$PARTITION]} != "_" ]]; then
		WARNING=${DISK_ALERT_INODE_WARNING[$PARTITION]}
	elif [[ _$DISK_ALERT_DEFAULT_INODE_WARNING != "_" ]]; then
		WARNING=$DISK_ALERT_DEFAULT_INODE_WARNING
	else
		WARNING="90"
	fi
	#
	# 100% is always fatal
	if [[ $USEP -eq "100" ]]; then
		echo '{
			"severity": "fatal",
			"service": "disk",
			"resource": "'$HOSTNAME':'$PARTITION'-inode",
			"event": "disk_alert_inode_usage_high",
			"origin": "disk_alert.sh",
			"text": "Inode usage fatal percentage detected",
			"value": "'$USEP'%",
			"correlate": ["disk_alert_inode_usage_ok"],
			"attributes": {
				"warning threshold": "'$WARNING'%",
				"critical threshold": "'$CRITICAL'%"
			}
		}' | /opt/sysadmws/notify_devilry/notify_devilry.py
		if [[ ! -z "${VMAGENT_URL}" ]]; then
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage_severity ${severity_fatal}
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage $USEP
		fi
	# Critical percent message
	elif [[ $USEP -ge $CRITICAL ]]; then
		echo '{
			"severity": "critical",
			"service": "disk",
			"resource": "'$HOSTNAME':'$PARTITION'-inode",
			"event": "disk_alert_inode_usage_high",
			"origin": "disk_alert.sh",
			"text": "Inode usage critical percentage detected",
			"value": "'$USEP'%",
			"correlate": ["disk_alert_inode_usage_ok"],
			"attributes": {
				"warning threshold": "'$WARNING'%",
				"critical threshold": "'$CRITICAL'%"
			}
		}' | /opt/sysadmws/notify_devilry/notify_devilry.py
		if [[ ! -z "${VMAGENT_URL}" ]]; then
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage_severity ${severity_critical}
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage $USEP
		fi
	elif [[ $USEP -ge $WARNING ]]; then
		echo '{
			"severity": "major",
			"service": "disk",
			"resource": "'$HOSTNAME':'$PARTITION'-inode",
			"event": "disk_alert_inode_usage_high",
			"origin": "disk_alert.sh",
			"text": "Inode usage warning percentage detected",
			"value": "'$USEP'%",
			"correlate": ["disk_alert_inode_usage_ok"],
			"attributes": {
				"warning threshold": "'$WARNING'%",
				"critical threshold": "'$CRITICAL'%"
			}
		}' | /opt/sysadmws/notify_devilry/notify_devilry.py
		if [[ ! -z "${VMAGENT_URL}" ]]; then
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage_severity ${severity_major}
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage $USEP
		fi
	else
		echo '{
			"severity": "ok",
			"service": "disk",
			"resource": "'$HOSTNAME':'$PARTITION'-inode",
			"event": "disk_alert_inode_usage_ok",
			"origin": "disk_alert.sh",
			"text": "Inode usage ok percentage detected",
			"value": "'$USEP'%",
			"correlate": ["disk_alert_inode_usage_high"],
			"attributes": {
				"warning threshold": "'$WARNING'%",
				"critical threshold": "'$CRITICAL'%"
			}
		}' | /opt/sysadmws/notify_devilry/notify_devilry.py
		if [[ ! -z "${VMAGENT_URL}" ]]; then
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage_severity ${severity_ok}
			send_disk_metric_to_victoria microdevops_agent_disk_alert_inode_usage_percentage $USEP
		fi
	fi
done
