cat /proc/cmdline

echo "----- GRUB -----"
grep '^GRUB_CMDLINE_LINUX' /etc/default/grub

echo "----- MKINITCPIO -----"
grep '^HOOKS=' /etc/mkinitcpio.conf

echo "----- SWAP -----"
swapon --show

echo "----- FSTAB -----"
grep -E 'swap|@swap' /etc/fstab

echo "----- BTRFS OFFSET -----"
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile

echo "----- RESUME DEVICE -----"
cat /sys/power/resume

echo "----- RESUME OFFSET -----"
cat /sys/power/resume_offset

echo "----- MAPPER -----"
ls -l /dev/mapper/

echo "----- PREVIOUS BOOT ERRORS -----"
journalctl -b -1 -k -p warning --no-pager | tail -100cat /proc/cmdline

echo "----- GRUB -----"
grep '^GRUB_CMDLINE_LINUX' /etc/default/grub

echo "----- MKINITCPIO -----"
grep '^HOOKS=' /etc/mkinitcpio.conf

echo "----- SWAP -----"
swapon --show

echo "----- FSTAB -----"
grep -E 'swap|@swap' /etc/fstab

echo "----- BTRFS OFFSET -----"
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile

echo "----- RESUME DEVICE -----"
cat /sys/power/resume

echo "----- RESUME OFFSET -----"
cat /sys/power/resume_offset

echo "----- MAPPER -----"
ls -l /dev/mapper/

echo "----- PREVIOUS BOOT ERRORS -----"
journalctl -b -1 -k -p warning --no-pager | tail -100
