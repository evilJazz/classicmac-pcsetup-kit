#!/bin/bash
#
# PCSetup-Kit
#
# Copyright (C) 2019 Andre Beckedorf
#       <evilJazz _AT_ katastrophos _DOT_ net>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

SCRIPT_FILENAME=$(readlink -f "`cd \`dirname \"$0\"\`; pwd`/`basename \"$0\"`")
SCRIPT_ROOT=$(dirname "$SCRIPT_FILENAME")

set -e -o pipefail

echoerr()
{
   echo "$@" 1>&2
}

sudomagic()
{
   echoerr "sudo $@"
   sudo "$@"
   return $?
}

usage()
{
   echo "Usage: $0 ACTION ..."
   echo
   echo "ACTIONs:"
   echo "         create  -  Create a new image file"
   echo "        adapter  -  Create a VMDK adapter for an existing image file"
   echo "          mount  -  Mount image (requires root / sudo privileges)"
   echo "         umount  -  Un-mount image (requires root / sudo privileges)"
   echo
}

[ $# == 0 ] && usage && exit 1

getUUID()
{
   if [ $(which uuidgen) != "" ]; then
      uuidgen
   elif [ -f "/proc/sys/kernel/random/uuid" ]; then
      cat cat /proc/sys/kernel/random/uuid
   else
      echo "NONE"
   fi
}

createImageAction()
{
   usage()
   {
      echo "Usage: $0 create (PCSetup image filename) (Size In MB) [options]"
      echo
      echo "Options:"
      echo "     --no-partiioning   Only create image file. Do not create partitions in image."
      echo "     --no-format        Do not format image file."
      echo "     --preseed=dir      Copy files in directory 'dir' to image."
      echo "     --no-vmdk-file     Do not create an VMDK adapter file for Virtual Box or VMware."
   }

   [ $# -lt 2 ] && usage && exit 1
   
     
   IMAGEFILE=$1
   IMAGEFILE_MBSIZE=$2

   IMAGE_INITIALIZATION=1
   IMAGE_FORMAT=1
   IMAGE_PRESEED=0
   IMAGE_VMDK_ADAPTER=1

   for i in "$@"; do
      case $i in
         --no-partitioning)
            IMAGE_INITIALIZATION=0
            IMAGE_FORMAT=0
            ;;
         --no-format)
            IMAGE_FORMAT=0
            ;;
         --preseed*)
            IMAGE_PRESEED=1
            IMAGE_PRESEED_SRC="${i#*=}"

            if [ "$IMAGE_PRESEED_SRC" == "" ]; then
               echoerr "Please specify a source directory with --preseed=<some directory>"
               exit 1
            fi

            if [ ! -d "$IMAGE_PRESEED_SRC" ]; then
               echoerr "The preseed directory $IMAGE_PRESEED_SRC does not exist."
               exit 1
            fi

            ;;
         --no-vmdk-file)
            IMAGE_VMDK_ADAPTER=0
            ;;
         *)
            ;;
      esac
   done
   #exit 0
   dd if=/dev/zero of="$IMAGEFILE" bs=1M count=$IMAGEFILE_MBSIZE

   if [ $IMAGE_INITIALIZATION -eq 1 ]; then
      sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk -c=dos -H 64 -S 32 "$IMAGEFILE"
o # clear the in memory partition table
n # new partition
p # primary partition
1 # partition number 1
  # default - start at beginning of disk 
  # default - use all remaining space
t # Change partition type
6 # FAT16
a # make a partition bootable
p # print the in-memory partition table
w # write the partition table
q # and we're done
EOF

      LOOPDEV=$(sudomagic losetup -f -P --show "$IMAGEFILE")
      LOOPPART="${LOOPDEV}p1"

      if [ $IMAGE_FORMAT -eq 1 ]; then
         sudomagic mkdosfs -F16 -v "$LOOPPART"

         if [ $IMAGE_PRESEED -eq 1 ]; then
            MOUNTPOINT=/tmp/$$
            mkdir -p "$MOUNTPOINT"

            sudomagic mount "$LOOPPART" "$MOUNTPOINT"
            sudomagic rsync -rptuv --progress --stats "$IMAGE_PRESEED_SRC/"* "$MOUNTPOINT" || true
            echo "Press enter to un-mount $MOUNTPOINT..."
            read
            sudomagic umount "$MOUNTPOINT"

            rmdir "$MOUNTPOINT"
         fi
      fi

      sudomagic losetup -d "$LOOPDEV"
   fi

   if [ $IMAGE_VMDK_ADAPTER == 1 ]; then
      createVMDKAdapterAction "$IMAGEFILE"
   fi
}

createVMDKAdapterAction()
{
   usage()
   {
      echo "Usage: $0 adapter [PCSetup image filename]"
      echo
   }

   [ $# != 1 ] && usage && exit 1

   IMAGEFILE=$1
   IMAGEFILE_BASE=$(basename "$IMAGEFILE")
   IMAGEFILE_SIZE=$(stat -c%s "$IMAGEFILE")
   IMAGEFILE_SECTORS=$(($IMAGEFILE_SIZE / 512))
   IMAGEFILE_MBSIZE=$(($IMAGEFILE_SIZE / 1024 / 1024))

   OUTFILE="$IMAGEFILE.vmdk"

   cat > "$IMAGEFILE.vmdk" << VMDK
# Disk DescriptorFile
version=1
CID=$(getUUID | cut -d"-" -f1)
parentCID=ffffffff
createType="fullDevice"

# Extent description
RW $IMAGEFILE_SECTORS FLAT "$IMAGEFILE_BASE" 0

# The disk Data Base 
#DDB

ddb.virtualHWVersion = "4"
ddb.adapterType="ide"
ddb.geometry.cylinders="$IMAGEFILE_MBSIZE"
ddb.geometry.heads="64"
ddb.geometry.sectors="32"
ddb.uuid.image="$(getUUID)"
ddb.uuid.parent="00000000-0000-0000-0000-000000000000"
ddb.uuid.modification="$(getUUID)"
ddb.uuid.parentmodification="00000000-0000-0000-0000-000000000000"
ddb.geometry.biosCylinders="$IMAGEFILE_MBSIZE"
ddb.geometry.biosHeads="64"
ddb.geometry.biosSectors="32"
VMDK

   echo "$OUTFILE successfully created."
}

mountImageAction()
{
   usage()
   {
      echo "Usage: $0 mount (PCSetup image filename) (mountpoint)"
      echo
   }

   [ $# -lt 1 ] && usage && exit 1
   
   IMAGEFILE=$(realpath "$1")
   MOUNTPOINT=$(realpath "${2:-/mnt/temp}")

   # Search for existing loop device
   LOOPDEV=$(sudo losetup | grep "$IMAGEFILE" | tail -n1 | cut -f1 -d' ' || true)

   if [ -n "$LOOPDEV" ]; then
      echoerr "$IMAGEFILE is already attached at $LOOPDEV."
      exit 1
   fi

   LOOPDEV=$(sudomagic losetup -f -P --show "$IMAGEFILE")
   LOOPPART="${LOOPDEV}p1"

   mkdir -p "$MOUNTPOINT"
   sudomagic mount -o uid=$(id -u),gid=$(id -g) "$LOOPPART" "$MOUNTPOINT"

   echo "Mounted $IMAGEFILE at $MOUNTPOINT. You can use"
   echo "$0 umount '$1'"
   echo "to un-mount the image."
   echo
}

umountImageAction()
{
   usage()
   {
      echo "Usage: $0 umount (PCSetup image filename)"
      echo
   }

   [ $# -lt 1 ] && usage && exit 1
   
   IMAGEFILE=$(realpath "$1")
   
   LOOPDEV=$(sudo losetup | grep "$IMAGEFILE" | tail -n1 | cut -f1 -d' ' || true)

   if [ ! -e "$LOOPDEV" ]; then
      echoerr "Could not find loop device for $IMAGEFILE."
      exit 1
   fi

   LOOPPART="${LOOPDEV}"
   MOUNTPOINT=$(sudo mount | grep "$LOOPPART" | tail -n1 | cut -f3 -d' ' || true)

   if [ -d "$MOUNTPOINT" ]; then
      sudomagic umount "$MOUNTPOINT"
   fi

   sudomagic losetup -d "$LOOPDEV"

   echo "Successfully un-mounted $IMAGEFILE."
}

ACTION=$1
shift 1

case "$ACTION" in
"create")
   createImageAction "$@"
   ;;
"adapter")
   createVMDKAdapterAction "$@"
   ;;
"mount")
   mountImageAction "$@"
   ;;
"umount")
   umountImageAction "$@"
   ;;
*)
   usage
   ;;
esac
