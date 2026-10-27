set -e
busybox mke2fs -F /dev/vdd
mkdir -p /mnt/image
mount -t ext2 /dev/vdd /mnt/image
mkdir -p /mnt/image/build-input
tar -xf /dev/vdc -C /mnt/image/build-input
tar -xzf /mnt/image/build-input/rootfs.tar.gz -C /mnt/image
mkdir -p /mnt/image/build-input/tools /mnt/image/build-input/e2fs
tar -xf /mnt/image/build-input/tools.tar -C /mnt/image/build-input/tools
tar -xf /mnt/image/build-input/e2fs.tar -C /mnt/image/build-input/e2fs
mount -t devtmpfs devtmpfs /mnt/image/dev
mount -t proc proc /mnt/image/proc
chroot /mnt/image /bin/sh -c 'apk --no-network add /build-input/tools/packages/*.apk /build-input/e2fs/packages/*.apk'
umount /mnt/image/proc
umount /mnt/image/dev
rm -rf /mnt/image/build-input
mkdir -p /mnt/image/workspace /mnt/image/dev /mnt/image/proc /mnt/image/sys
sync
umount /mnt/image
printf 'DSH_ALPINE_IMAGE_BUILT\n'
