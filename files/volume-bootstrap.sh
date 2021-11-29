#!/bin/bash

until ((jq -V && aws --version) > /dev/null 2>&1); do echo "Waiting for cloud-init..."; sleep 1; done

REGION=$(wget -q -O - http://169.254.169.254/latest/dynamic/instance-identity/document | jq '.region' -r)
ZONE=$(wget -q -O - http://169.254.169.254/latest/dynamic/instance-identity/document | jq '.availabilityZone' -r)
INSTANCE_ID=$(wget -q -O - http://169.254.169.254/latest/dynamic/instance-identity/document | jq '.instanceId' -r)
SIZE=${volume_size}
FILTERS='Name=tag:apptr_block_type,Values=${block_type} Name=tag:apptr_k3s_type,Values=${k3s_type} Name=tag:apptr_application_hash,Values=${application_hash}'
TAG_SPECIFICATIONS='ResourceType=volume,Tags=[{Key=apptr_block_type,Value=${block_type}},{Key=Name,Value=${application_hash}-cloud-init},{Key=apptr_k3s_type,Value=${k3s_type}},{Key=apptr_application_hash,Value=${application_hash}}]'
DEVICE=${device}
PARTITION=$DEVICE"1"
MOUNT_PATH=${mount_path}
SNAPSHOT_ID=
VOLUME_ID=

aws configure set region $REGION

function create_nvme_to_ebs_mapping() {
    NVME_BLOCKS=$(lsblk -r | grep nvme | awk '{print $1}' | xargs -I{} sh -c 'sudo ebsnvme-id -b /dev/{} | xargs -I% echo {}:%' | grep -e 'nvme[0-9]*n1:'$DEVICE)
    for nvme_block in $NVME_BLOCKS
    do
        local block_name
        block_name=$(echo $nvme_block | cut -f1 -d:)
        sudo ln -s /dev/$block_name $DEVICE
        sudo ln -s /dev/$block_name"p1" $PARTITION
        echo $block_name" is mapped to device "$DEVICE
    done
}

function check_attached_volume() {
    echo "Checking for attached volumes..."
    VOLUME_ID=$( aws ec2 describe-volumes  --filter Name=attachment.instance-id,Values=$INSTANCE_ID Name=attachment.device,Values=$DEVICE  --query "Volumes[*].{ID:VolumeId}" --output text)
    [  -z "$VOLUME_ID" ] && echo 'No volumes attached.' || echo "volume-id "$VOLUME_ID" found."
}

function check_volume_available() {
    echo "Checking for available volumes..."
    VOLUME_ID=$(aws ec2 describe-volumes  --filters $FILTERS Name=availability-zone,Values=$ZONE Name=status,Values=available  \
		    --query "Volumes[*].{ID:VolumeId,time:CreateTime}" --no-paginate --output text | \
            xargs -I% echo % | awk '{system("echo "$0" $(date --date "$2" +%s)  ");}' | \
            sort -k3 -n -r | head -n 1 | cut -f1 -d' '
	     )
    if [  -z "$VOLUME_ID" ]; then
	echo 'No volumes available!'
    else
	echo "volume-id "$VOLUME_ID" found."
    fi
}

function check_snapshot_available() {
    echo "Checking for compatible snapshots..."
    SNAPSHOT_ID=$(aws ec2 describe-snapshots  --filters $FILTERS  --query "Snapshots[*].{id:SnapshotId,time:StartTime}" --no-paginate  --output text | \
            xargs -I% echo % | awk '{system("echo "$0" $(date --date "$2" +%s)  ");}' | \
            sort -k3 -n -r | head -n 1 | cut -f1 -d' '
		   )
    if [  -z "$SNAPSHOT_ID" ]; then
	echo 'No snapshot available.'
    else
	echo "snapshot-id "$SNAPSHOT_ID" found."
    fi
}

function create_volume_from_snapshot() {
    echo "Creating new volume from snapshot-id:"$SNAPSHOT_ID
    VOLUME_ID=$(aws ec2 create-volume --snapshot-id $SNAPSHOT_ID --availability-zone $ZONE --tag-specifications $TAG_SPECIFICATIONS --query "VolumeId" --output text)
    while [ $(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query "Volumes[*].State" --output text) != "available" ]; do \
            sleep 1
        echo "Waiting for state available..."
    done
    echo "volume-id "$VOLUME_ID" is created."
}


function create_empty_volume() {
    echo "Creating empty volume..."
    VOLUME_ID=$(aws ec2 create-volume --size $SIZE --volume-type gp2 --availability-zone $ZONE --tag-specifications $TAG_SPECIFICATIONS --query "VolumeId" --output text)
    while [ $(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query "Volumes[*].State" --output text) != "available" ]; do \
            sleep 1
        echo "Waiting for state available..."
    done
    echo "Volume "$VOLUME_ID" is available now."
}

function create_new_volume() {
    check_snapshot_available
    [ -z "$SNAPSHOT_ID" ] && create_empty_volume || create_volume_from_snapshot
}


function attach_volume() {
    echo "Attaching volume ""$VOLUME_ID"" to instance ""$INSTANCE_ID"
    aws ec2 attach-volume --volume-id "$VOLUME_ID" --instance-id "$INSTANCE_ID" --device $DEVICE
    while [ $(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --query "Volumes[*].State" --output text) != "in-use" ]; do \
            sleep 1
        echo "Waiting for in-use state..."
    done
    echo "Volume "$VOLUME_ID" is in-use now."
}

function touch_partition_table() {
    local N_PARTITION

    while [ $(ls $DEVICE > /dev/null 2>&1  && echo 1 || echo 0) -ne 1 ]; do \
            echo "Waiting for device "$DEVICE" ..."
        sleep 1
    done
    N_PARTITION=$(lsblk $DEVICE --json | jq '.blockdevices[0].children | length')

    if [[ $N_PARTITION -eq 0 ]]
    then
        echo 'start=2048, type=83' | sudo sfdisk /dev/sdx
        sleep 2
        sudo mkfs.xfs $PARTITION
    else
        echo "Filesystem already exists."
    fi
}

function mount_partition() {
    local IS_MOUNTED
    IS_MOUNTED=$(mount | grep $MOUNT_PATH)
    if [[ -z "$IS_MOUNTED" ]]
    then
        echo "Mounting partition "$PARTITION" to "$MOUNT_PATH"..."
        sudo mkdir -p $MOUNT_PATH
        sudo mount $PARTITION $MOUNT_PATH && \
            echo "Partition "$PARTITION" mounted."
    else
        echo "Partition "$PARTITION" already mounted to "$MOUNT_PATH
    fi
}

check_attached_volume
if [ -z "$VOLUME_ID" ]
then
    check_volume_available
    if [ -z "$VOLUME_ID" ]
    then
        create_new_volume
    else
        echo "Re-using volume"$VOLUME_ID
    fi
    attach_volume
fi

create_nvme_to_ebs_mapping
touch_partition_table
mount_partition

sudo touch /var/lib/rancher/.apptr_server_is_backup
