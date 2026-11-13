# DB1 Setup

## Storage

	lsblk
	file -s /dev/nvme1n1
	mkfs -t ext4 /dev/nvme1n1
	mkdir /data
	mount /dev/nvme1n1 /data
	blkid /dev/nvme1n1

/etc/fstab

	UUID=your-uuid-here /mnt/data ext4 defaults,nofail 0 2


