#!/bin/bash
# ./vzbackup-rclone.sh rehydrate YYYY/MM/DD file_name_encrypted.bin

############ /START CONFIG
drive="drive"
dumpdir="/mnt/Elements/dump" # Set this to where your vzdump files are stored
remoteroot="Proxmox Backups" # Set this to the remote backup directory
MAX_AGE=1 # This is the age in days to keep local backup copies. Local backups older than this are deleted.
MAX_CLOUD_AGE=21 # This is the age in days to keep cloud backup copies. Cloud backups older than this are deleted
############ /END CONFIG

rclone_conf="/root/.config/rclone/rclone.conf"
_bdir="$dumpdir"
timepath="$(date +%Y)/$(date +%m)/$(date +%d)"
COMMAND=${1}
rehydrate=${2} #enter the date you want to rehydrate in the following format: YYYY/MM/DD
if [ -n "${3}" ]; then
    CMDARCHIVE=$(echo "/${3}" | sed -e 's/\(.bin\)*$//g')
fi
tarfile=${TARGET}

if [[ ${COMMAND} == 'rehydrate' ]]; then
    rclone --config "$rclone_conf" \
    --drive-chunk-size=32M copy "$drive:/$remoteroot/$rehydrate$CMDARCHIVE" "$dumpdir" \
    -v --stats=60s --transfers=16 --checkers=16
fi

if [[ ${COMMAND} == 'job-start' ]]; then
    echo "Deleting local backups older than $MAX_AGE days."
    # Only this script's own artifacts, so nothing else stored in $dumpdir is touched.
    find "$dumpdir" -maxdepth 1 -type f \
        \( -name 'vzdump-*' -o -name 'proxmox_backup_*' \) \
        -mtime +"$MAX_AGE" -print -delete
fi

if [[ ${COMMAND} == 'backup-end' ]]; then
    echo "rcloning $tarfile to $remoteroot/$timepath"
    rclone --config "$rclone_conf" \
    --drive-chunk-size=32M copy "$tarfile" "$drive:/$remoteroot/$timepath" \
    -v --stats=60s --transfers=16 --checkers=16
fi

if [[ ${COMMAND} == 'job-end' || ${COMMAND} == 'job-abort' ]]; then
    echo "Backing up main PVE configs"
    _tdir=${TMP_DIR:-/var/tmp}
    _tdir=$(mktemp -d "$_tdir/proxmox-XXXXXXXX")
    function clean_up {
        echo "Cleaning up"
        rm -rf "$_tdir"
    }
    trap clean_up EXIT
    _now=$(date +%Y-%m-%d.%H.%M.%S)
    _HOSTNAME=$(hostname -f)
    _filename1="$_tdir/proxmoxetc.$_now.tar"
    _filename2="$_tdir/proxmoxpve.$_now.tar"
    _filename3="$_tdir/proxmoxroot.$_now.tar"
    _filename4="$_tdir/proxmox_backup_${_HOSTNAME}_${_now}.tar.gz"

    echo "Tar files"
    # copy key system files
    tar --warning='no-file-ignored' -cPf "$_filename1" /etc/.
    tar --warning='no-file-ignored' -cPf "$_filename2" /var/lib/pve-cluster/.
    # /root minus credentials that would grant access to this host or the Drive itself if the
    # Drive were compromised; rclone is re-authorised on a rebuild anyway.
    tar --warning='no-file-ignored' --exclude='.ssh' --exclude='.config/rclone' \
        -cPf "$_filename3" /root/.

    echo "Compressing files"
    # archive the copied system files
    tar -czPf "$_filename4" "$_tdir"/*.tar

    # copy config archive to backup folder
    cp -v "$_filename4" "$_bdir/"
    echo "rcloning $_filename4"
    rclone --config "$rclone_conf" \
    --drive-chunk-size=32M move "$_filename4" "$drive:/$remoteroot/$timepath" \
    -v --stats=60s --transfers=16 --checkers=16

    # Prune only after a successful job that actually landed guest backups in today's folder.
    # Otherwise a run of failing nights would age out every good copy, permanently.
    if [[ ${COMMAND} == 'job-end' ]]; then
        _fresh=$(rclone --config "$rclone_conf" lsf --files-only --include 'vzdump-*' \
            "$drive:/$remoteroot/$timepath" 2>/dev/null | wc -l)
    else
        _fresh=0
    fi
    if [[ $_fresh -gt 0 ]]; then
        echo "rclone deleting files older than ${MAX_CLOUD_AGE} days ($_fresh fresh backups today)"
        rclone --config "$rclone_conf" \
            delete --drive-use-trash=false --min-age "${MAX_CLOUD_AGE}d" "$drive:/$remoteroot/"
        echo "rclone removing empty folders"
        rclone --config "$rclone_conf" \
            rmdirs "$drive:/$remoteroot/" --leave-root
    else
        echo "Skipping cloud prune: ${COMMAND}, $_fresh guest backups in $remoteroot/$timepath"
    fi
fi
