#!/bin/bash

if [ -z $NEO4J_ADDR ]; then
  echo "You must specify a NEO4J_ADDR env var with port, such as my-neo4j:6362"
  exit 1
fi

if [ -z $DATABASE ]; then
  echo "You must specify a DATABASE env var; comma-separated list of databases to backup, such as neo4j,system"
  exit 1
fi

if [ -z $CLOUD_PROVIDER ]; then
  echo "You must specify a CLOUD_PROVIDER env var"
  exit 1
fi

if [ -z $BUCKET ]; then
  echo "You must specify a BUCKET address such as (gs|s3)://my-backups"
  exit 1
fi

if [ -z $HEAP_SIZE ]; then
  export HEAP_SIZE=2G
fi

if [ -z $PAGE_CACHE ]; then
  export PAGE_CACHE=2G
fi

if [ -z $FALLBACK_TO_FULL ]; then
  export FALLBACK_TO_FULL="true"
fi

if [ -z $CHECK_CONSISTENCY ]; then
  export CHECK_CONSISTENCY="true"
fi

if [ -z $CHECK_INDEXES ]; then
  export CHECK_INDEXES="true"
fi

if [ -z $CHECK_GRAPH ]; then
  export CHECK_GRAPH="true"
fi

if [ -z $CHECK_LABEL_SCAN_STORE ]; then
  export CHECK_LABEL_SCAN_STORE="true"
fi

if [ -z $CHECK_PROPERTY_OWNERS ]; then
  export CHECK_PROPERTY_OWNERS="false"
fi

function cloud_copy() {
  backup_path=$1
  database=$2

  bucket_path=""
  if [ "${BUCKET: -1}" = "/" ]; then
      bucket_path="${BUCKET%?}/$database/"
  else
      bucket_path="$BUCKET/$database/"
  fi

  echo "Pushing $backup_path -> $bucket_path"

  case $CLOUD_PROVIDER in
  aws)
    aws s3 cp $backup_path $bucket_path
    aws s3 cp $backup_path "${bucket_path}${LATEST_POINTER}"
    ;;
  gcp)
    gsutil cp $backup_path $bucket_path
    gsutil cp $backup_path "${bucket_path}${LATEST_POINTER}"
    ;;
  azure)
    # Container is specified via BUCKET input, which can contain a path, i.e.
    # my-container/foo
    # AZ CLI doesn't allow this so we need to split it into container and container path.
    IFS='/' read -r -a pathParts <<< "$BUCKET"
    CONTAINER=${pathParts[0]}

    # See: https://stackoverflow.com/a/10987027
    CONTAINER_PATH=${BUCKET#$CONTAINER}
        
    CONTAINER_FILE=$CONTAINER_PATH/$database/$(basename "$backup_path")
    # Remove all leading and doubled slashes to avoid creating empty folders in azure
    CONTAINER_FILE=$(echo "$CONTAINER_FILE" | sed 's|^/*||')
    CONTAINER_FILE=$(echo "$CONTAINER_FILE" | sed s'|//|/|g')

    echo "Azure storage blob copy to $CONTAINER :: $CONTAINER_FILE"
    az storage blob upload --container-name "$CONTAINER" \
                       --file "$backup_path" \
                       --name $CONTAINER_FILE \
                       --account-name "$ACCOUNT_NAME" \
                       --account-key "$ACCOUNT_KEY"

    latest_name=$CONTAINER_PATH/$database/${LATEST_POINTER}
    # Remove all leading and doubled slashes to avoid creating empty folders in azure
    latest_name=$(echo "$latest_name" | sed 's|^/*||')
    latest_name=$(echo "$latest_name" | sed s'|//|/|g')

    echo "Azure storage blob copy to $CONTAINER :: $latest_name"
    az storage blob upload --container-name "$CONTAINER" \
                       --file "$backup_path" \
                       --name "$latest_name" \
                       --account-name "$ACCOUNT_NAME" \
                       --account-key "$ACCOUNT_KEY"
    ;;
  esac
}

function backup_database() {
  db=$1

  export BACKUP_SET="$db-$(date "+%Y-%m-%d-%H:%M:%S")"
  export LATEST_POINTER="$db-latest.tar.gz"

  echo "=============== BACKUP $db ==================="
  echo "Beginning backup from $NEO4J_ADDR to /data/$BACKUP_SET"
  echo "Using heap size $HEAP_SIZE and page cache $PAGE_CACHE"
  echo "FALLBACK_TO_FULL=$FALLBACK_TO_FULL, CHECK_CONSISTENCY=$CHECK_CONSISTENCY"
  echo "CHECK_GRAPH=$CHECK_GRAPH CHECK_INDEXES=$CHECK_INDEXES"
  echo "CHECK_LABEL_SCAN_STORE=$CHECK_LABEL_SCAN_STORE CHECK_PROPERTY_OWNERS=$CHECK_PROPERTY_OWNERS"
  echo "To storage bucket $BUCKET using $CLOUD_PROVIDER"
  echo "============================================================"

  neo4j-admin backup \
    --from="$NEO4J_ADDR" \
    --backup-dir=/data \
    --database=$db \
    --pagecache=$PAGE_CACHE \
    --fallback-to-full=$FALLBACK_TO_FULL \
    --check-consistency=$CHECK_CONSISTENCY \
    --check-graph=$CHECK_GRAPH \
    --check-indexes=$CHECK_INDEXES \
    --check-label-scan-store=$CHECK_LABEL_SCAN_STORE \
    --check-property-owners=$CHECK_PROPERTY_OWNERS \
    --verbose

  # Docs: see exit codes here: https://neo4j.com/docs/operations-manual/current/backup/performing/#backup-performing-command
  backup_result=$?
  case $backup_result in
  0) echo "Backup succeeded - $db" ;;
  1) echo "Backup FAILED - $db" ;;
  2) echo "Backup succeeded but consistency check failed - $db" ;;
  3) echo "Backup succeeded but consistency check found inconsistencies - $db" ;;
  esac

  if [ $backup_result -eq 1 ]; then
    echo "Aborting other actions; backup failed"
    exit 1
  fi

  echo "Backup size:"
  du -hs "/data/$db"

  echo "Final Backupset files"
  ls -l "/data/$db"

  echo "Archiving and Compressing -> /data/$BACKUP_SET.tar"

  tar -zcvf "/data/$BACKUP_SET.tar.gz" "/data/$db" --remove-files

  if [ $? -ne 0 ]; then
    echo "BACKUP ARCHIVING OF $db FAILED"
    exit 1
  fi

  echo "Zipped backup size:"
  du -hs "/data/$BACKUP_SET.tar.gz"

  cloud_copy "/data/$BACKUP_SET.tar.gz" $db

  if [ $? -ne 0 ]; then
    echo "Storage copy of backup for $db FAILED"
    exit 1
  fi
}

function activate_gcp() {
  local credentials="/credentials/credentials"
  if [[ -f "${credentials}" ]]; then
    echo "Activating google credentials before beginning"
    gcloud auth activate-service-account --key-file "${credentials}"
    if [ $? -ne 0 ]; then
      echo "Credentials failed; no way to copy to google."
      exit 1
    fi
  else
    echo "No credentials file found. Assuming workload identity is configured"
  fi
}

function activate_aws() {
  echo "Activating aws credentials before beginning"
  mkdir -p /root/.aws/
  cp /credentials/credentials ~/.aws/config

  if [ $? -ne 0 ]; then
    echo "Credentials failed; no way to copy to aws."
    exit 1
  fi

  aws sts get-caller-identity
  if [ $? -ne 0 ]; then
    echo "Credentials failed; no way to copy to aws."
    exit 1
  fi
}

function activate_azure() {
  echo "Activating azure credentials before beginning"
  source "/credentials/credentials"

  if [ -z $ACCOUNT_NAME ]; then
    echo "You must specify a ACCOUNT_NAME export statement in the credentials secret which is the storage account where backups are stored"
    exit 1
  fi

  if [ -z $ACCOUNT_KEY ]; then
    echo "You must specify a ACCOUNT_KEY export statement in the credentials secret which is the storage account where backups are stored"
    exit 1
  fi
}

case $CLOUD_PROVIDER in
azure)
  activate_azure
  ;;
aws)
  activate_aws
  ;;
gcp)
  activate_gcp
  ;;
*)
  echo "Invalid CLOUD_PROVIDER=$CLOUD_PROVIDER"
  echo "You must set CLOUD_PROVIDER to be one of (aws|gcp|azure)"
  exit 1
  ;;
esac

# Split by comma
IFS=","
read -a databases <<<"$DATABASE"
for db in "${databases[@]}"; do
  backup_database "$db"
done

echo "All finished"
exit 0
