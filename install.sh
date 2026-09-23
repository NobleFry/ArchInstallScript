$()$(
  bash
  #!/usr/bin/env bash
  set -Eeuo pipefail

  # ============================================================
  # Arch Linux Installer
  # UEFI + LUKS2 + Btrfs + GRUB + NetworkManager
  #
  # WARNING:
  #   This script WILL format the selected ROOT partition.
  #   If you choose to format the EFI partition, all data on that
  #   EFI partition will also be erased.
  #
  #   If you are dual-booting with Windows and reusing the existing
  #   Windows EFI System Partition, DO NOT format it.
  # ============================================================

  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'

  log() { echo -e "${GREEN}[+]${NC} $*"; }
  info() { echo -e "${BLUE}[*]${NC} $*"; }
  warn() { echo -e "${YELLOW}[!]${NC} $*"; }
  die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
  }

  trap 'echo -e "\n${RED}[ERROR]${NC} Command failed at line ${LINENO}."; exit 1' ERR

  [[ $EUID -eq 0 ]] || die "This script must be run as root."
  [[ -d /sys/firmware/efi/efivars ]] || die "The system is not booted in UEFI mode."

  clear

  cat <<'EOF'
============================================================
              Arch Linux Installer
              LUKS2 + Btrfs + GRUB
============================================================

IMPORTANT:

1. The selected ROOT partition will be completely erased.
2. If you already have a Windows EFI partition, do NOT format it.
3. Back up all important data before continuing.
4. Make sure you select the correct disk and partitions.

EOF

  # ------------------------------------------------------------
  # Network
  # ------------------------------------------------------------

  echo "Network connection method:"
  echo "1) Wired network / already connected"
  echo "2) Wi-Fi using iwctl"
  read -rp "Select an option [1/2]: " NETWORK_TYPE

  if [[ "$NETWORK_TYPE" == "2" ]]; then
    info "Opening iwctl."
    echo
    echo "Useful iwctl commands:"
    echo "  device list"
    echo "  station wlan0 scan"
    echo "  station wlan0 get-networks"
    echo "  station wlan0 connect \"WiFi-Name\""
    echo "  exit"
    echo
    read -rp "Press Enter to open iwctl..."
    iwctl
  fi

  log "Testing network connectivity..."

  if ! ping -c 3 -W 3 archlinux.org >/dev/null 2>&1; then
    warn "Unable to reach archlinux.org. Testing 1.1.1.1..."
    ping -c 3 -W 3 1.1.1.1 >/dev/null 2>&1 ||
      die "Network connectivity test failed."
  fi

  log "Network connection is working."

  # ------------------------------------------------------------
  # System clock
  # ------------------------------------------------------------

  log "Enabling NTP synchronization..."

  timedatectl set-ntp true
  timedatectl status --no-pager || true

  # ------------------------------------------------------------
  # Mirror selection
  # ------------------------------------------------------------

  echo
  echo "Pacman mirror selection:"
  echo "1) China mirrors"
  echo "2) International mirrors"
  read -rp "Select an option [1/2]: " MIRROR_TYPE

  cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

  if [[ "$MIRROR_TYPE" == "1" ]]; then
    log "Using China mirrors."

    cat >/etc/pacman.d/mirrorlist <<'EOF'
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
EOF
  else
    log "Using the existing international mirror list."
    cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
  fi

  log "Updating Arch Linux keyring..."

  pacman -Sy --noconfirm archlinux-keyring

  # ------------------------------------------------------------
  # Disk setup
  # ------------------------------------------------------------

  echo
  info "Available block devices:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,FSVER,LABEL,MOUNTPOINTS,MODEL

  echo
  warn "If the disk has not been partitioned yet, you may launch cfdisk now."
  echo
  echo "Recommended layout:"
  echo
  echo "  EFI  : 1-2 GiB, EFI System Partition"
  echo "  ROOT : Remaining space, Linux filesystem"
  echo
  echo "If a Windows EFI System Partition already exists, reuse it."
  echo "Do NOT format the existing Windows EFI partition."
  echo

  read -rp "Run cfdisk now? [y/N]: " RUN_CFDISK

  if [[ "$RUN_CFDISK" =~ ^[Yy]$ ]]; then
    read -rp "Enter the target disk, for example /dev/nvme0n1 or /dev/sda: " INSTALL_DISK

    [[ -b "$INSTALL_DISK" ]] || die "$INSTALL_DISK is not a valid block device."

    cfdisk "$INSTALL_DISK"

    partprobe "$INSTALL_DISK" || true
    sleep 2

    lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINTS "$INSTALL_DISK"
  fi

  echo
  lsblk -f

  echo
  read -rp "Enter the EFI partition, for example /dev/nvme0n1p1: " EFI_PART
  read -rp "Enter the Arch root partition, for example /dev/nvme0n1p2: " ROOT_PART

  [[ -b "$EFI_PART" ]] || die "EFI partition does not exist: $EFI_PART"
  [[ -b "$ROOT_PART" ]] || die "Root partition does not exist: $ROOT_PART"
  [[ "$EFI_PART" != "$ROOT_PART" ]] || die "EFI and root partitions cannot be the same partition."

  echo
  warn "The ROOT partition $ROOT_PART will be completely erased and converted to LUKS2."
  read -rp "Type YES to continue: " CONFIRM

  [[ "$CONFIRM" == "YES" ]] || die "Installation cancelled."

  # ------------------------------------------------------------
  # EFI partition
  # ------------------------------------------------------------

  echo
  echo "Selected EFI partition: $EFI_PART"
  read -rp "Format the EFI partition? New installations usually use y; Windows dual-boot usually uses N [y/N]: " FORMAT_EFI

  if [[ "$FORMAT_EFI" =~ ^[Yy]$ ]]; then
    warn "The EFI partition $EFI_PART will be formatted as FAT32."
    read -rp "Type FORMAT-EFI to confirm: " EFI_CONFIRM

    [[ "$EFI_CONFIRM" == "FORMAT-EFI" ]] || die "EFI formatting cancelled."

    umount "$EFI_PART" 2>/dev/null || true
    mkfs.fat -F32 "$EFI_PART"
  else
    info "Keeping the existing EFI filesystem."

    EFI_FS=$(lsblk -no FSTYPE "$EFI_PART" || true)

    if [[ "$EFI_FS" != "vfat" ]]; then
      warn "The filesystem on $EFI_PART is '${EFI_FS:-unknown}'."
      warn "An EFI System Partition normally uses FAT32/vfat."
      read -rp "Continue anyway? [y/N]: " CONTINUE

      [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 1
    fi
  fi

  # ------------------------------------------------------------
  # LUKS2 encryption
  # ------------------------------------------------------------

  log "Creating LUKS2 encrypted container..."

  cryptsetup luksFormat \
    --type luks2 \
    "$ROOT_PART"

  log "Opening encrypted container..."

  cryptsetup open "$ROOT_PART" cryptroot

  # ------------------------------------------------------------
  # Btrfs
  # ------------------------------------------------------------

  log "Creating Btrfs filesystem..."

  mkfs.btrfs -f -L ArchLinux /dev/mapper/cryptroot

  log "Creating Btrfs subvolumes..."

  mount /dev/mapper/cryptroot /mnt

  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@swap

  umount /mnt

  # ------------------------------------------------------------
  # Mount filesystems
  # ------------------------------------------------------------

  BTRFS_OPTS="noatime,compress=zstd:3,ssd,discard=async"

  log "Mounting Btrfs subvolumes..."

  mount -o "${BTRFS_OPTS},subvol=@" \
    /dev/mapper/cryptroot /mnt

  mkdir -p /mnt/{home,boot,swap}

  mount -o "${BTRFS_OPTS},subvol=@home" \
    /dev/mapper/cryptroot /mnt/home

  mount -o "noatime,subvol=@swap" \
    /dev/mapper/cryptroot /mnt/swap

  mount "$EFI_PART" /mnt/boot

  # ------------------------------------------------------------
  # Swapfile
  # ------------------------------------------------------------

  echo
  read -rp "Swap size in GiB [32]: " SWAP_SIZE
  SWAP_SIZE=${SWAP_SIZE:-32}

  [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] || die "Swap size must be an integer."
  ((SWAP_SIZE > 0)) || die "Swap size must be greater than 0 GiB."

  log "Creating ${SWAP_SIZE} GiB swapfile..."

  if btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
    btrfs filesystem mkswapfile \
      --size "${SWAP_SIZE}G" \
      /mnt/swap/swapfile
  else
    warn "btrfs filesystem mkswapfile is not available."
    warn "Using compatibility method."

    touch /mnt/swap/swapfile
    chattr +C /mnt/swap/swapfile
    btrfs property set /mnt/swap/swapfile compression none || true

    dd if=/dev/zero \
      of=/mnt/swap/swapfile \
      bs=1M \
      count=$((SWAP_SIZE * 1024)) \
      status=progress

    chmod 600 /mnt/swap/swapfile
    mkswap /mnt/swap/swapfile
  fi

  swapon /mnt/swap/swapfile

  # ------------------------------------------------------------
  # Verify mounts
  # ------------------------------------------------------------

  echo
  log "Mounted filesystems:"
  findmnt /mnt

  echo
  log "Active swap:"
  swapon --show

  # ------------------------------------------------------------
  # Install base system
  # ------------------------------------------------------------

  log "Installing Arch Linux base system..."

  pacstrap -K /mnt \
    base \
    base-devel \
    linux \
    linux-headers \
    linux-firmware \
    btrfs-progs \
    cryptsetup \
    networkmanager \
    grub \
    efibootmgr \
    os-prober \
    sudo \
    vim \
    neovim \
    fish \
    fastfetch

  # ------------------------------------------------------------
  # Generate fstab
  # ------------------------------------------------------------

  log "Generating fstab..."

  genfstab -U /mnt >/mnt/etc/fstab

  echo
  cat /mnt/etc/fstab

  # ------------------------------------------------------------
  # Basic configuration
  # ------------------------------------------------------------

  echo
  read -rp "Hostname [archlinux]: " HOSTNAME
  HOSTNAME=${HOSTNAME:-archlinux}

  read -rp "Timezone [Asia/Singapore]: " TIMEZONE
  TIMEZONE=${TIMEZONE:-Asia/Singapore}

  [[ -e "/mnt/usr/share/zoneinfo/$TIMEZONE" ]] ||
    die "Invalid timezone: $TIMEZONE"

  # ------------------------------------------------------------
  # CPU microcode
  # ------------------------------------------------------------

  CPU_VENDOR=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')

  case "$CPU_VENDOR" in
  GenuineIntel)
    MICROCODE="intel-ucode"
    ;;
  AuthenticAMD)
    MICROCODE="amd-ucode"
    ;;
  *)
    MICROCODE=""
    warn "Unable to detect Intel or AMD CPU."
    warn "No microcode package will be installed automatically."
    ;;
  esac

  if [[ -n "$MICROCODE" ]]; then
    log "Detected CPU vendor: $CPU_VENDOR"
    log "Installing $MICROCODE..."

    pacstrap -K /mnt "$MICROCODE"
  fi

  # ------------------------------------------------------------
  # Get LUKS UUID
  # ------------------------------------------------------------

  LUKS_UUID=$(cryptsetup luksUUID "$ROOT_PART")

  [[ -n "$LUKS_UUID" ]] || die "Unable to read LUKS UUID."

  log "LUKS UUID: $LUKS_UUID"

  # ------------------------------------------------------------
  # Create post-install chroot script
  # ------------------------------------------------------------

  cat >/mnt/root/arch-postinstall.sh <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

HOSTNAME='$HOSTNAME'
TIMEZONE='$TIMEZONE'
LUKS_UUID='$LUKS_UUID'

echo "[+] Configuring timezone..."

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "[+] Configuring locale..."

sed -i \
    -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    -e 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' \
    /etc/locale.gen

locale-gen

echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "[+] Configuring hostname..."

echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "[+] Configuring mkinitcpio..."

sed -i \
    's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
    /etc/mkinitcpio.conf

mkinitcpio -P

echo "[+] Configuring GRUB..."

cp /etc/default/grub /etc/default/grub.backup

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    sed -i \
        "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=5 nowatchdog rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@\"|" \
        /etc/default/grub
else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=5 nowatchdog rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@\"" \
        >> /etc/default/grub
fi

if grep -q '^#*GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i \
        's/^#*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' \
        /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

if grep -q '^#*GRUB_SAVEDEFAULT=' /etc/default/grub; then
    sed -i \
        's/^#*GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' \
        /etc/default/grub
else
    echo 'GRUB_SAVEDEFAULT=true' >> /etc/default/grub
fi

if grep -q '^#*GRUB_DEFAULT=' /etc/default/grub; then
    sed -i \
        's/^#*GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
        /etc/default/grub
else
    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
fi

echo "[+] Installing GRUB..."

grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=ARCH \
    --recheck

echo "[+] Searching for other operating systems..."

os-prober || true

echo "[+] Generating GRUB configuration..."

grub-mkconfig -o /boot/grub/grub.cfg

echo "[+] Enabling NetworkManager..."

systemctl enable NetworkManager

echo
echo "============================================================"
echo "Set the root password"
echo "============================================================"

passwd root

echo
echo "[+] Chroot configuration completed."
EOF

  chmod +x /mnt/root/arch-postinstall.sh

  log "Running post-install configuration inside chroot..."

  arch-chroot /mnt /root/arch-postinstall.sh

  rm -f /mnt/root/arch-postinstall.sh

  # ------------------------------------------------------------
  # Optional regular user
  # ------------------------------------------------------------

  echo
  read -rp "Create a regular user? [Y/n]: " CREATE_USER

  if [[ ! "$CREATE_USER" =~ ^[Nn]$ ]]; then
    read -rp "Username: " USERNAME

    if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      arch-chroot /mnt useradd \
        -m \
        -G wheel \
        -s /bin/bash \
        "$USERNAME"

      echo
      info "Set the password for $USERNAME:"
      arch-chroot /mnt passwd "$USERNAME"

      echo '%wheel ALL=(ALL:ALL) ALL' \
        >/mnt/etc/sudoers.d/10-wheel

      chmod 440 /mnt/etc/sudoers.d/10-wheel

      log "User $USERNAME created and added to the wheel group."
    else
      warn "Invalid username format."
      warn "Skipping user creation."
    fi
  fi

  # ------------------------------------------------------------
  # Finish
  # ------------------------------------------------------------

  sync

  echo
  echo "============================================================"
  echo "             Arch Linux installation complete"
  echo "============================================================"
  echo
  echo "Root partition:"
  echo "  $ROOT_PART"
  echo
  echo "EFI partition:"
  echo "  $EFI_PART"
  echo
  echo "LUKS UUID:"
  echo "  $LUKS_UUID"
  echo
  echo "Hostname:"
  echo "  $HOSTNAME"
  echo
  echo "Timezone:"
  echo "  $TIMEZONE"
  echo
  echo "Swap size:"
  echo "  ${SWAP_SIZE} GiB"
  echo
  echo "Recommended checks before rebooting:"
  echo
  echo "  cat /mnt/etc/fstab"
  echo "  cat /mnt/etc/default/grub"
  echo "  ls /mnt/boot/EFI/ARCH"
  echo
  echo "When everything looks correct, run:"
  echo
  echo "  swapoff /mnt/swap/swapfile"
  echo "  umount -R /mnt"
  echo "  cryptsetup close cryptroot"
  echo "  reboot"
  echo
  echo "Remove the Arch installation media after rebooting."
  echo
)$()
