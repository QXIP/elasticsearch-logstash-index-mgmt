#!/bin/bash
# 
# elasticsearch-snapshot-index.sh
#
# Script to back up your cluster (or individual indices) easily, using the new Snapshot Restore API.
# Note: REQUIRES ES 1.0+
#
# --- CREATE INDEX:
# $ curl -XPUT 'http://localhost:9200/_snapshot/my_backup' -d '{
#     "type": "fs",
#     "settings": {
#         "compress" : true,
#         "location": "/mnt2/elasticsearch/backup"
#     }
# }'
#
# --- SHOW INDEX:
# $ curl -XGET 'http://localhost:9200/_snapshot/my_backup?pretty'
#
# --- CREATE FULL SNAPSHOT:
# $ curl -XPUT 'http://localhost:9200/_snapshot/my_backup/snapshot_1?wait_for_completion=false'
#
# --- CREATE SELECTIVE SNAPSHOT:
# $ curl -XPUT "localhost:9200/_snapshot/my_backup/snapshot_1" -d '{
#     "indices": "kibana-int",
#     "ignore_unavailable": "true",
#     "include_global_state": false
# }'
#
# --- LIST ALL SNAPSHOTS:
# $ curl -XGET 'http://localhost:9200/_snapshot/my_backup/_all'
#
# --- RESTORE SNAPSHOT:
# $ curl -XPOST 'http://localhost:9200/_snapshot/my_backup/snapshot_1/_restore'
#
#
#   http://logstash.net
#   http://www.elasticsearch.org
#
# Must run on an elasticsearch node, and expects to find the index on this node.

usage()
{
cat << EOF

elasticsearch-snapshot-index.sh

Create a restorable backup of an elasticsearch index (assumes Logstash format
indexes), and upload it to an existing S3 bucket. The default backs up an
index from yesterday. Note that this script itself does not restart 
elasticsearch - the restore script that is generated for each backup will 
restart elasticsearch after restoring an archived index.

USAGE: ./elasticsearch-snapshot-index.sh -b SNAP_REPOSITORY -n SNAP_NAME [OPTIONS]

OPTIONS:
  -h    Show this message
  -b    Snapshot Repository (Required)
  -n    Snapshot Name (Required unless -l)
  -i    Snapshot Indexes (default: all)
  -t    Cluster directory for archiving (default: /tmp)
  -l    Show snapshot details only (read-only mode)
  -r    Restore snapshot (*MUST* match -n parameter for safety)
  -e    Elasticsearch URL (default: http://localhost:9200)

EXAMPLES:

  ./elasticsearch-snapshot-index.sh -l -b "my_backup" -n "snapshot_1"
    This uses http://localhost:9200 to connect to elasticsearch, fetches the snapshot
    details in the specified repository (default without -n is all snapshots in repo)

  ./elasticsearch-snapshot-index.sh -b "my_backup" -n "snapshot_1"

    This uses http://localhost:9200 to connect to elasticsearch, creates a snapshot
    repository if needed, and a full cluster snapshot under remote server's /tmp

  ./elasticsearch-snapshot-index.sh -b "my_backup" -i -n "snapshot_1" -i "kibana-int,logstash" -t "/mnt/es/bk" -e "http://127.0.0.1:9200"

    This uses http://localhost:9200 to connect to elasticsearch, creates a snapshot
    repository if needed, and a snapshot of the selected indexes (incremental) stored
    under "/mnt/es/bk" on the remote cluster server its being executed on.

  ./elasticsearch-snapshot-index.sh -b "my_backup" -n "snapshot_1" -r "snapshot_1"

    This uses http://localhost:9200 to connect to elasticsearch and restores snapshot
    "snapshot_1" from repository "my_backup" located on the cluster. Can accept the
    same options as the creation for specifying specific indexes to restore.

EOF
}

if [ "$USER" != 'root' ] && [ "$LOGNAME" != 'root' ]; then
  # I don't want to troubleshoot the permissions of others
  echo "This script must be run as root."
  exit 1
fi

# Defaults
TMP_DIR="/tmp"
ELASTICSEARCH="http://localhost:9200"
WAIT="yes"

# Validate shard/replica values
RE_D="^[0-9]+$"

while getopts ":b:i:n:t:e:w:ps:h:r:l" flag
do
  case "$flag" in
    h)
      usage
      exit 0
      ;;
    b)
      S_REPO=$OPTARG
      ;;
    i)
      INDEXES=$OPTARG
      ;;
    n)
      S_NAME=$OPTARG
      ;;
    t)
      TMP_DIR=$OPTARG
      ;;
    e)
      ELASTICSEARCH=$OPTARG
      ;;
    w)
      WAIT=$OPTARG
      ;;
    l)
      LIST=1
      ;;
    r)
      RESTORE=$OPTARG
      ;;
    ?)
      usage
      exit 1
      ;;
  esac
done

# We need an S3 base path 
if [ -z "$S_REPO" ]; then
  ERROR="${ERROR}Please provide a repository for your snapshot -b.\n"
fi

# We need an elasticsearch index directory
if [[ -z "S_NAME" && ! -z "$LIST" ]]; then
  ERROR="${ERROR}Please provide an name for your snapshot -n.\n"
fi

# If we have errors, show the errors with usage data and exit.
if [ -n "$ERROR" ]; then
  echo -e $ERROR
  usage
  exit 1
fi

# List mode?
if [ -n $LIST ]; then
	echo;
	# If no snapshot name specified, show all
	if [ -z "$S_NAME" ]; then
	   echo "Showing ALL snapshots in repository $S_REPO"
	   curl -XGET "$ELASTICSEARCH/_snapshot/$S_REPO/_all"
	else 
	   echo "Showing $S_NAME snapshots in repository $S_REPO"
	   curl -XGET "$ELASTICSEARCH/_snapshot/$S_REPO/$S_NAME"
	fi
	echo
	echo
	exit 0;
fi

# Restore mode?
if [ -n $RESTORE ]; then
	# Let's play it safe here
	if [[ ! $RESTORE == $S_NAME ]]
	then
	  echo "Safe Lock: Snapshot NAME and RESTORE not matching!";
	  echo; exit 0;
	fi

	echo;
	echo "Fetching snapshot details..."
	echo
	REPO_TEST=`curl -s -XGET "$ELASTICSEARCH/_snapshot/$S_REPO/$S_NAME"`
	if [[ $REPO_TEST == *error* ]]
	then
	  echo "Repository $S_REPO not found!";
	  echo; exit 0;
	else echo $REPO_TEST
	fi

	read -p "Are you sure you want to restore this snapshot? (y/n)?" choice
	case "$choice" in 
	  y|Y ) 
	   	echo "Restoring $S_NAME snapshots from repository $S_REPO ..."
		if [ -n $INDEXES ]; then
		  # selective restore
	  	  curl -XPUT "$ELASTICSEARCH/_snapshot/$S_REPO/$S_NAME/_restore" -d '{"indices": "$INDEXES","ignore_unavailable": "true","include_global_state": false}'
		else
		  # full restore
	   	  curl -XGET "$ELASTICSEARCH/_snapshot/$S_REPO/$S_NAME/_restore"
		fi
		;;
	  n|N ) 
		echo "Mission abandoned! Exiting..."
		;;
	  * ) 
		echo "Exiting..."
		;;
	esac

	echo
	echo
	exit 0;
fi

# Create Snapshot?
# Get snapshot repository details from Elasticsearch

REPO_TEST=`curl -s -XGET "$ELASTICSEARCH/_snapshot/$S_REPO"`
if [[ $REPO_TEST == *error* ]]
then
  echo "Repository $S_REPO not found! Creating one...";
  curl -XPUT '$ELASTICSEARCH/_snapshot/$S_REPO' -d '{"type": "fs","settings": {"compress" : true,"location": "$TMP_DIR"}}'
fi

# Check if FULL or SELECTIVE snapshot
if [ -n $INDEXES ]; then
	# selective
	curl -XPUT "$ELASTICSEARCH/_snapshot/$S_REPO/$S_NAME" -d '{"indices": "$INDEXES","ignore_unavailable": "true","include_global_state": false}'
else
	# full snap
	curl -XPUT "$ELASTICSEARCH/_snapshot/$S_REPO/$S_NAME?wait_for_completion=$WAIT"
fi

echo
exit 0
