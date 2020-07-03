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

usage()
{
   echo "Usage: $0 ACTION ..."
   echo
   echo "ACTIONs:"
   echo "         create  -  Create a new image file"
   echo "        adapter  -  Create a VMDK adapter for an existing image file"
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
   
     
   OUTFILE=$1
   OUTFILE_MBSIZE=$2

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
               echo "Please specify a source directory with --preseed=<some directory>"
               exit 1
            fi

            if [ ! -d "$IMAGE_PRESEED_SRC" ]; then
               echo "The preseed directory $IMAGE_PRESEED_SRC does not exist."
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
   dd if=/dev/zero of="$OUTFILE" bs=1M count=$OUTFILE_MBSIZE

   if [ $IMAGE_INITIALIZATION -eq 1 ]; then
      sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk -c=dos -H 64 -S 32 "$OUTFILE"
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

      LOOPDEV=$(sudo losetup -f -P --show "$OUTFILE")
      LOOPPART="${LOOPDEV}p1"

      set -x

      if [ $IMAGE_FORMAT -eq 1 ]; then
         sudo mkdosfs -F16 -v "$LOOPPART"

         if [ $IMAGE_PRESEED -eq 1 ]; then
            sudo mount "$LOOPPART" /mnt/temp
            sudo rsync -rptuv --progress --stats "$IMAGE_PRESEED_SRC/"* /mnt/temp/
            echo Press enter to unmount /mnt/temp...
            read
            sudo umount /mnt/temp
         fi
      fi

      sudo losetup -d "$LOOPDEV"
   fi

   set +x

   if [ $IMAGE_VMDK_ADAPTER == 1 ]; then
      createVMDKAdapterAction "$OUTFILE"
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

ACTION=$1
shift 1

case "$ACTION" in
"create")
   createImageAction "$@"
   ;;
"adapter")
   createVMDKAdapterAction "$@"
   ;;
*)
   usage
   ;;
esac
