$()$(
  bash
  #!/usr/bin/env bash

  set -Eeuo pipefail

  # ============================================================
  # Arch Linux Installation Script
  #
  # Features:
  #   - UEFI only
  #   - LUKS2 encrypted root
  #   - Btrfs
  #   - Btrfs subvolumes:
  #       @
  #       @home
  #       @swap
  #   - Optional Btrfs swapfile
  #   - Optional hibernation
  #   - systemd-based initramfs + sd-encrypt
  #   - GRUB UEFI
  #   - Intel / AMD microcode auto detection
  #   - NetworkManager
  #   - Optional Windows dual boot / os-prober
  #   - China / International mirrors
  #
  # IMPORTANT:
  #   The selected ROOT partition WILL be erased.
  #   The EFI partition is only formatted if explicitly confirmed.
  #
  #   If you reuse an existing Windows EFI System Partition,
  #   DO NOT format it.
  # ============================================================

  # ------------------------------------------------------------
  # Colors
  # ------------------------------------------------------------

  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'

  # ------------------------------------------------------------
  # Helper functions
  # ------------------------------------------------------------

  log() {
    echo -e "${GREEN}[+]${NC} $*"
  }

  info() {
    echo -e "${BLUE}[*]${NC} $*"
  }

  warn() {
    echo -e "${YELLOW}[!]${NC} $*"
  }

  die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
  }

  confirm() {
    local prompt="$1"
    local reply

    read -rp "$prompt [y/N]: " reply

    [[ "$reply" =~ ^[Yy]$ ]]
  }

  pause() {
    read -rp "Press Enter to continue..."
  }

  command_exists() {
    command -v "$1" >/dev/null 2>&1
  }

  # ------------------------------------------------------------
  # Error handler
  # ------------------------------------------------------------

  error_handler() {
    local exit_code=$?
    local line_no=$1

    echo
    echo -e "${RED}[ERROR]${NC} Installation failed."
    echo -e "${RED}[ERROR]${NC} Line: ${line_no}"
    echo -e "${RED}[ERROR]${NC} Exit code: ${exit_code}"
    echo
    echo "The installer has stopped to avoid making further changes."
    echo
    echo "Current mounts can be inspected with:"
    echo
    echo "  findmnt /mnt"
    echo "  lsblk -f"
    echo
    echo "If necessary, clean up manually with:"
    echo
    echo "  swapoff /mnt/swap/swapfile 2>/dev/null || true"
    echo "  umount -R /mnt 2>/dev/null || true"
    echo "  cryptsetup close cryptroot 2>/dev/null || true"
    echo

    exit "$exit_code"
  }

  trap 'error_handler "$LINENO"' ERR

  # ------------------------------------------------------------
  # Basic environment checks
  # ------------------------------------------------------------

  [[ $EUID -eq 0 ]] || die "This installer must be run as root."

  [[ -r /etc/arch-release ]] ||
    die "This does not appear to be an Arch Linux environment."

  [[ -d /sys/firmware/efi/efivars ]] || {
    echo
    die "The Arch ISO is not booted in UEFI mode.

Reboot and select the UEFI entry for your installation media.

For example:

    UEFI: SanDisk USB

Do NOT select:

    SanDisk USB

if that entry boots the device in Legacy BIOS / CSM mode."
  }

  command_exists pacstrap ||
    die "pacstrap is not available. Boot from the official Arch Linux ISO."

  command_exists arch-chroot ||
    die "arch-chroot is not available."

  command_exists cryptsetup ||
    die "cryptsetup is not available."

  command_exists btrfs ||
    die "btrfs-progs is not available."

  # ------------------------------------------------------------
  # Make sure /mnt is clean
  # ------------------------------------------------------------

  if mountpoint -q /mnt; then
    die "/mnt is already mounted.

Unmount the existing installation first:

    umount -R /mnt

Then run this installer again."
  fi

  if [[ -e /dev/mapper/cryptroot ]]; then
    die "/dev/mapper/cryptroot already exists.

Close it first:

    cryptsetup close cryptroot"
  fi

  # ------------------------------------------------------------
  # Header
  # ------------------------------------------------------------

  clear

  cat <<'EOF'
============================================================
              Arch Linux Installer
============================================================

Configuration:

  Boot mode       : UEFI
  Root encryption : LUKS2
  Filesystem      : Btrfs
  Bootloader      : GRUB
  Initramfs       : systemd + sd-encrypt
  Networking      : NetworkManager

Btrfs subvolumes:

  @       -> /
  @home   -> /home
  @swap   -> /swap

WARNING:

  The selected ROOT partition WILL be erased.

  If you already have Windows installed and reuse its EFI
  System Partition, DO NOT format that EFI partition.

============================================================

EOF

  pause

  # ============================================================
  # 1. NETWORK
  # ============================================================

  echo
  echo "============================================================"
  echo " Network configuration"
  echo "============================================================"
  echo

  echo "1) Wired network / network already connected"
  echo "2) Wi-Fi using iwctl"
  echo

  read -rp "Select network method [1/2]: " NETWORK_TYPE

  case "$NETWORK_TYPE" in

  1)
    info "Using existing network connection."
    ;;

  2)
    echo
    info "Opening iwctl."
    echo
    echo "Useful commands:"
    echo
    echo "  device list"
    echo "  station wlan0 scan"
    echo "  station wlan0 get-networks"
    echo "  station wlan0 connect \"WiFi-Name\""
    echo "  exit"
    echo

    pause

    iwctl
    ;;

  *)
    die "Invalid network option."
    ;;
  esac

  # ------------------------------------------------------------
  # Test connectivity
  # ------------------------------------------------------------

  echo
  log "Testing network connectivity..."

  if ping -c 3 -W 3 archlinux.org >/dev/null 2>&1; then

    log "Internet connection is working."

  elif ping -c 3 -W 3 1.1.1.1 >/dev/null 2>&1; then

    warn "IP connectivity works, but DNS resolution failed."
    die "Check DNS configuration before continuing."

  else

    die "No Internet connection detected."

  fi

  # ============================================================
  # 2. CLOCK
  # ============================================================

  echo
  log "Enabling network time synchronization..."

  timedatectl set-ntp true

  sleep 2

  timedatectl status --no-pager || true

  # ============================================================
  # 3. MIRROR SELECTION
  # ============================================================

  echo
  echo "============================================================"
  echo " Package mirrors"
  echo "============================================================"
  echo

  echo "1) China mirrors"
  echo "2) International mirrors"
  echo

  read -rp "Select mirror group [1/2]: " MIRROR_TYPE

  MIRRORLIST="/etc/pacman.d/mirrorlist"
  MIRRORLIST_BACKUP="/etc/pacman.d/mirrorlist.arch-installer-backup"

  cp -f "$MIRRORLIST" "$MIRRORLIST_BACKUP"

  case "$MIRROR_TYPE" in

  1)

    log "Using China mirrors."

    cat >"$MIRRORLIST" <<'EOF'
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
EOF

    ;;

  2)

    log "Using the mirror list provided by the Arch ISO."

    ;;

  *)

    die "Invalid mirror option."

    ;;
  esac

  # ------------------------------------------------------------
  # Keyring
  # ------------------------------------------------------------

  echo
  log "Synchronizing package databases and updating keyring..."

  pacman -Sy --needed --noconfirm archlinux-keyring

  # ============================================================
  # 4. DISK SELECTION
  # ============================================================

  echo
  echo "============================================================"
  echo " Disk configuration"
  echo "============================================================"
  echo

  lsblk \
    -o NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,PARTTYPENAME,LABEL,MOUNTPOINTS,MODEL

  echo
  echo "Recommended layout:"
  echo
  echo "  EFI  : 1-2 GiB, EFI System Partition"
  echo "  ROOT : remaining space, Linux filesystem"
  echo
  echo "The ROOT partition will contain LUKS2 + Btrfs."
  echo

  warn "Existing Windows users should normally reuse the existing EFI partition."
  warn "Do NOT format an existing Windows EFI partition."

  # ------------------------------------------------------------
  # Optional cfdisk
  # ------------------------------------------------------------

  echo

  if confirm "Run cfdisk now?"; then

    echo

    read -rp \
      "Enter target disk (example: /dev/nvme0n1 or /dev/sda): " \
      INSTALL_DISK

    [[ -b "$INSTALL_DISK" ]] ||
      die "$INSTALL_DISK is not a valid block device."

    echo
    warn "You are about to modify:"
    echo
    echo "  $INSTALL_DISK"
    echo

    pause

    cfdisk "$INSTALL_DISK"

    partprobe "$INSTALL_DISK" || true
    udevadm settle || true

    sleep 2

    echo
    lsblk \
      -o NAME,PATH,SIZE,TYPE,FSTYPE,PARTTYPENAME,MOUNTPOINTS \
      "$INSTALL_DISK"
  fi

  # ------------------------------------------------------------
  # Select partitions
  # ------------------------------------------------------------

  echo
  info "Current partitions:"
  echo

  lsblk -f

  echo

  read -rp \
    "Enter EFI partition (example: /dev/nvme0n1p1): " \
    EFI_PART

  read -rp \
    "Enter Arch ROOT partition (example: /dev/nvme0n1p2): " \
    ROOT_PART

  # ------------------------------------------------------------
  # Validate selected partitions
  # ------------------------------------------------------------

  [[ -b "$EFI_PART" ]] ||
    die "EFI partition does not exist: $EFI_PART"

  [[ -b "$ROOT_PART" ]] ||
    die "ROOT partition does not exist: $ROOT_PART"

  [[ "$EFI_PART" != "$ROOT_PART" ]] ||
    die "EFI and ROOT cannot be the same partition."

  if findmnt -rn -S "$ROOT_PART" >/dev/null 2>&1; then

    die "The selected ROOT partition is already mounted.

Unmount it before running the installer."

  fi

  ROOT_TYPE=$(lsblk -ndo TYPE "$ROOT_PART")

  [[ "$ROOT_TYPE" == "part" ]] ||
    die "$ROOT_PART is not a partition."

  # ------------------------------------------------------------
  # Display destructive operation summary
  # ------------------------------------------------------------

  echo
  echo "============================================================"
  echo -e "${RED}${BOLD} DESTRUCTIVE OPERATION WARNING${NC}"
  echo "============================================================"
  echo
  echo "EFI partition:"
  echo
  echo "  $EFI_PART"
  echo
  echo "ROOT partition to ERASE:"
  echo
  echo "  $ROOT_PART"
  echo
  echo "Everything currently stored on the ROOT partition will be lost."
  echo

  read -rp "Type ERASE-ROOT to continue: " ROOT_CONFIRM

  [[ "$ROOT_CONFIRM" == "ERASE-ROOT" ]] ||
    die "Installation cancelled."

  # ============================================================
  # 5. EFI PARTITION
  # ============================================================

  echo
  echo "============================================================"
  echo " EFI System Partition"
  echo "============================================================"
  echo

  EFI_FS=$(lsblk -ndo FSTYPE "$EFI_PART" || true)

  echo "EFI partition:"
  echo
  echo "  $EFI_PART"
  echo
  echo "Current filesystem:"
  echo
  echo "  ${EFI_FS:-unknown}"
  echo

  if confirm "Format the EFI partition as FAT32?"; then

    echo
    warn "DO NOT do this when reusing the Windows EFI partition."
    echo

    read -rp "Type FORMAT-EFI to continue: " EFI_CONFIRM

    [[ "$EFI_CONFIRM" == "FORMAT-EFI" ]] ||
      die "EFI formatting cancelled."

    umount "$EFI_PART" 2>/dev/null || true

    log "Formatting EFI partition..."

    mkfs.fat -F32 "$EFI_PART"

  else

    info "Keeping the existing EFI filesystem."

    EFI_FS=$(lsblk -ndo FSTYPE "$EFI_PART" || true)

    if [[ "$EFI_FS" != "vfat" ]]; then

      echo
      warn "The selected EFI partition does not appear to contain FAT32/vfat."
      warn "UEFI System Partitions normally use FAT32."
      echo

      confirm "Continue anyway?" ||
        die "Installation cancelled."

    fi
  fi

  # ============================================================
  # 6. LUKS2
  # ============================================================

  echo
  echo "============================================================"
  echo " LUKS2 encryption"
  echo "============================================================"
  echo

  log "Creating LUKS2 container on $ROOT_PART..."

  echo
  echo "You will now be asked to create the disk encryption password."
  echo

  cryptsetup luksFormat \
    --type luks2 \
    --verify-passphrase \
    "$ROOT_PART"

  echo
  log "Opening encrypted root..."

  cryptsetup open \
    "$ROOT_PART" \
    cryptroot

  [[ -b /dev/mapper/cryptroot ]] ||
    die "Failed to open the encrypted root volume."

  # ============================================================
  # 7. BTRFS
  # ============================================================

  echo
  log "Creating Btrfs filesystem..."

  mkfs.btrfs \
    -f \
    -L ArchLinux \
    /dev/mapper/cryptroot

  echo
  log "Creating Btrfs subvolumes..."

  mount /dev/mapper/cryptroot /mnt

  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@swap

  umount /mnt

  # ============================================================
  # 8. MOUNT BTRFS
  # ============================================================

  BTRFS_OPTS="noatime,compress=zstd:3,discard=async"

  log "Mounting Btrfs root subvolume..."

  mount \
    -o "${BTRFS_OPTS},subvol=@" \
    /dev/mapper/cryptroot \
    /mnt

  mkdir -p \
    /mnt/home \
    /mnt/boot \
    /mnt/swap

  log "Mounting Btrfs home subvolume..."

  mount \
    -o "${BTRFS_OPTS},subvol=@home" \
    /dev/mapper/cryptroot \
    /mnt/home

  log "Mounting Btrfs swap subvolume..."

  mount \
    -o "noatime,subvol=@swap" \
    /dev/mapper/cryptroot \
    /mnt/swap

  log "Mounting EFI partition..."

  mount "$EFI_PART" /mnt/boot

  # ============================================================
  # 9. SWAP / HIBERNATION
  # ============================================================

  echo
  echo "============================================================"
  echo " Swap and hibernation"
  echo "============================================================"
  echo

  MEM_KIB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)

  RAM_GIB=$(
    awk -v kib="$MEM_KIB" \
      'BEGIN {printf "%d", (kib + 1048575) / 1048576}'
  )

  echo "Detected RAM:"
  echo
  echo "  approximately ${RAM_GIB} GiB"
  echo

  HIBERNATION="no"

  if confirm "Configure hibernation support?"; then
    HIBERNATION="yes"
  fi

  if [[ "$HIBERNATION" == "yes" ]]; then

    DEFAULT_SWAP="$RAM_GIB"

    echo
    info "For hibernation, a swapfile large enough for the hibernation"
    info "image is required."
    echo
    echo "Suggested starting value: ${DEFAULT_SWAP} GiB"

  else

    DEFAULT_SWAP=8

  fi

  echo

  read -rp \
    "Swap size in GiB [${DEFAULT_SWAP}, 0 disables swap]: " \
    SWAP_SIZE

  SWAP_SIZE=${SWAP_SIZE:-$DEFAULT_SWAP}

  [[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] ||
    die "Swap size must be an integer."

  if [[ "$HIBERNATION" == "yes" && "$SWAP_SIZE" -eq 0 ]]; then

    die "Hibernation requires swap."

  fi

  SWAP_OFFSET=""

  if ((SWAP_SIZE > 0)); then

    echo
    log "Creating ${SWAP_SIZE} GiB Btrfs swapfile..."

    btrfs filesystem mkswapfile \
      --size "${SWAP_SIZE}G" \
      --uuid clear \
      /mnt/swap/swapfile

    swapon /mnt/swap/swapfile

    echo
    log "Swap activated."

    swapon --show

    if [[ "$HIBERNATION" == "yes" ]]; then

      echo
      log "Calculating Btrfs swapfile resume offset..."

      SWAP_OFFSET=$(
        btrfs inspect-internal map-swapfile \
          -r \
          /mnt/swap/swapfile
      )

      [[ "$SWAP_OFFSET" =~ ^[0-9]+$ ]] ||
        die "Failed to calculate Btrfs swapfile resume offset."

      log "Resume offset: $SWAP_OFFSET"

    fi

  fi

  # ============================================================
  # 10. VERIFY MOUNTS
  # ============================================================

  echo
  echo "============================================================"
  echo " Filesystem verification"
  echo "============================================================"
  echo

  findmnt /mnt

  echo

  if ((SWAP_SIZE > 0)); then
    swapon --show
  fi

  echo

  btrfs filesystem usage /mnt || true

  echo

  pause

  # ============================================================
  # 11. CPU MICROCODE
  # ============================================================

  CPU_VENDOR=$(
    awk -F ': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo
  )

  MICROCODE_PACKAGE=""

  case "$CPU_VENDOR" in

  GenuineIntel)
    MICROCODE_PACKAGE="intel-ucode"
    ;;

  AuthenticAMD)
    MICROCODE_PACKAGE="amd-ucode"
    ;;

  *)
    warn "Unable to identify Intel or AMD CPU."
    warn "CPU microcode will not be installed automatically."
    ;;
  esac

  if [[ -n "$MICROCODE_PACKAGE" ]]; then

    log "CPU detected: $CPU_VENDOR"
    log "Microcode package: $MICROCODE_PACKAGE"

  fi

  # ============================================================
  # 12. INSTALL BASE SYSTEM
  # ============================================================

  echo
  echo "============================================================"
  echo " Installing Arch Linux"
  echo "============================================================"
  echo

  PACKAGES=(
    base
    base-devel
    linux
    linux-headers
    linux-firmware

    btrfs-progs
    cryptsetup

    grub
    efibootmgr
    os-prober
    fuse3
    ntfs-3g

    networkmanager
    iwd

    sudo

    vim
    neovim

    fish
    fastfetch

    man-db
    man-pages
  )

  if [[ -n "$MICROCODE_PACKAGE" ]]; then
    PACKAGES+=("$MICROCODE_PACKAGE")
  fi

  log "Installing packages..."

  pacstrap \
    -K \
    /mnt \
    "${PACKAGES[@]}"

  # ============================================================
  # 13. FSTAB
  # ============================================================

  echo
  log "Generating fstab..."

  genfstab -U /mnt >/mnt/etc/fstab

  # Ensure swapfile entry exists.

  if ((SWAP_SIZE > 0)); then

    if ! grep -q '/swap/swapfile' /mnt/etc/fstab; then

      echo \
        "/swap/swapfile none swap defaults 0 0" \
        >>/mnt/etc/fstab

    fi

  fi

  echo
  cat /mnt/etc/fstab
  echo

  # ============================================================
  # 14. OPTIONAL WINDOWS ESP
  # ============================================================

  WINDOWS_EFI_PART=""

  echo
  echo "============================================================"
  echo " Windows dual boot"
  echo "============================================================"
  echo

  if [[ -f /mnt/boot/EFI/Microsoft/Boot/bootmgfw.efi ]]; then

    log "Windows Boot Manager found on the selected EFI partition."

  else

    info "Windows Boot Manager was not found on the selected EFI partition."

    echo
    echo "If Windows uses a different EFI System Partition, it can be"
    echo "temporarily mounted so os-prober can detect Windows."
    echo

    if confirm "Mount a separate Windows EFI partition?"; then

      echo
      lsblk -f
      echo

      read -rp \
        "Enter Windows EFI partition: " \
        WINDOWS_EFI_PART

      [[ -b "$WINDOWS_EFI_PART" ]] ||
        die "Invalid Windows EFI partition."

      [[ "$WINDOWS_EFI_PART" != "$ROOT_PART" ]] ||
        die "Windows EFI partition cannot be the Arch ROOT partition."

      mkdir -p /mnt/windows-efi

      mount \
        -o ro \
        "$WINDOWS_EFI_PART" \
        /mnt/windows-efi

    fi

  fi

  # ============================================================
  # 15. USER CONFIGURATION
  # ============================================================

  echo
  echo "============================================================"
  echo " System configuration"
  echo "============================================================"
  echo

  # ------------------------------------------------------------
  # Hostname
  # ------------------------------------------------------------

  read -rp "Hostname [archlinux]: " HOSTNAME

  HOSTNAME=${HOSTNAME:-archlinux}

  [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] ||
    die "Invalid hostname."

  # ------------------------------------------------------------
  # Timezone
  # ------------------------------------------------------------

  read -rp "Timezone [Asia/Singapore]: " TIMEZONE

  TIMEZONE=${TIMEZONE:-Asia/Singapore}

  [[ -e "/mnt/usr/share/zoneinfo/$TIMEZONE" ]] ||
    die "Invalid timezone: $TIMEZONE"

  # ------------------------------------------------------------
  # User
  # ------------------------------------------------------------

  echo

  CREATE_USER="yes"

  if ! confirm "Create a regular user?"; then
    CREATE_USER="no"
  fi

  USERNAME=""

  if [[ "$CREATE_USER" == "yes" ]]; then

    echo

    read -rp "Username: " USERNAME

    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
      die "Invalid username."

  fi

  # ============================================================
  # 16. LUKS UUID
  # ============================================================

  LUKS_UUID=$(cryptsetup luksUUID "$ROOT_PART")

  [[ "$LUKS_UUID" =~ ^[0-9a-fA-F-]+$ ]] ||
    die "Unable to obtain the LUKS UUID."

  log "LUKS UUID: $LUKS_UUID"

  # ============================================================
  # 17. WRITE INSTALL CONFIG
  # ============================================================

  CONFIG_FILE="/mnt/root/arch-install.conf"

  {
    printf 'HOSTNAME=%q\n' "$HOSTNAME"
    printf 'TIMEZONE=%q\n' "$TIMEZONE"
    printf 'LUKS_UUID=%q\n' "$LUKS_UUID"
    printf 'HIBERNATION=%q\n' "$HIBERNATION"
    printf 'SWAP_OFFSET=%q\n' "$SWAP_OFFSET"
    printf 'CREATE_USER=%q\n' "$CREATE_USER"
    printf 'USERNAME=%q\n' "$USERNAME"

  } >"$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"

  # ============================================================
  # 18. POST-INSTALL SCRIPT
  # ============================================================

  POSTINSTALL="/mnt/root/arch-postinstall.sh"

  cat >"$POSTINSTALL" <<'CHROOT_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

source /root/arch-install.conf


log() {
    echo "[+] $*"
}


die() {
    echo "[ERROR] $*" >&2
    exit 1
}


# ============================================================
# TIMEZONE
# ============================================================

log "Configuring timezone..."

ln -sf \
    "/usr/share/zoneinfo/$TIMEZONE" \
    /etc/localtime


hwclock --systohc


# ============================================================
# LOCALE
# ============================================================

log "Configuring locale..."


sed -i \
    -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    -e 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' \
    /etc/locale.gen


locale-gen


echo 'LANG=en_US.UTF-8' > /etc/locale.conf


# Keep early-boot keyboard predictable for LUKS password entry.

echo 'KEYMAP=us' > /etc/vconsole.conf


# ============================================================
# HOSTNAME
# ============================================================

log "Configuring hostname..."


echo "$HOSTNAME" > /etc/hostname


cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF


# ============================================================
# MKINITCPIO
# ============================================================

log "Configuring systemd-based initramfs with sd-encrypt..."


cp \
    /etc/mkinitcpio.conf \
    /etc/mkinitcpio.conf.arch-installer-backup


sed -i \
    's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
    /etc/mkinitcpio.conf


# ============================================================
# GRUB KERNEL PARAMETERS
# ============================================================

log "Configuring GRUB kernel parameters..."


GRUB_PARAMS="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw loglevel=5 nowatchdog"


if [[ "$HIBERNATION" == "yes" ]]; then

    [[ "$SWAP_OFFSET" =~ ^[0-9]+$ ]] || \
        die "Invalid swap resume offset."

    GRUB_PARAMS+=" resume=/dev/mapper/cryptroot resume_offset=${SWAP_OFFSET}"

fi


cp \
    /etc/default/grub \
    /etc/default/grub.arch-installer-backup


if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then

    sed -i \
        "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"|" \
        /etc/default/grub

else

    echo \
        "GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"" \
        >> /etc/default/grub

fi


# ------------------------------------------------------------
# Saved default entry
# ------------------------------------------------------------

if grep -q '^#\?GRUB_DEFAULT=' /etc/default/grub; then

    sed -i \
        's/^#\?GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \
        /etc/default/grub

else

    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub

fi


if grep -q '^#\?GRUB_SAVEDEFAULT=' /etc/default/grub; then

    sed -i \
        's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' \
        /etc/default/grub

else

    echo 'GRUB_SAVEDEFAULT=true' >> /etc/default/grub

fi


# ------------------------------------------------------------
# Enable os-prober
# ------------------------------------------------------------

if grep -q '^#\?GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then

    sed -i \
        's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' \
        /etc/default/grub

else

    echo \
        'GRUB_DISABLE_OS_PROBER=false' \
        >> /etc/default/grub

fi


# NOTE:
#
# GRUB_ENABLE_CRYPTODISK is intentionally NOT enabled.
#
# /boot is the unencrypted EFI System Partition.
# GRUB reads the kernel and initramfs directly from /boot.
#
# sd-encrypt inside the initramfs unlocks the encrypted root
# filesystem afterwards.


# ============================================================
# INITRAMFS
# ============================================================

log "Generating initramfs..."

mkinitcpio -P


# ============================================================
# INSTALL GRUB
# ============================================================

log "Installing GRUB UEFI bootloader..."


grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=ARCH \
    --recheck


# ============================================================
# WINDOWS DETECTION
# ============================================================

log "Running os-prober..."


os-prober || true


# ============================================================
# GRUB CONFIG
# ============================================================

log "Generating GRUB configuration..."


grub-mkconfig \
    -o /boot/grub/grub.cfg


# ============================================================
# NETWORKMANAGER
# ============================================================

log "Enabling NetworkManager..."


systemctl enable NetworkManager


# ============================================================
# ROOT PASSWORD
# ============================================================

echo
echo "============================================================"
echo " Set the root password"
echo "============================================================"
echo


passwd root


# ============================================================
# REGULAR USER
# ============================================================

if [[ "$CREATE_USER" == "yes" ]]; then

    echo
    log "Creating user: $USERNAME"


    useradd \
        -m \
        -G wheel \
        -s /bin/bash \
        "$USERNAME"


    echo
    echo "Set the password for $USERNAME:"
    echo


    passwd "$USERNAME"


    cat > /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF


    chmod 440 /etc/sudoers.d/10-wheel


    visudo -cf /etc/sudoers.d/10-wheel

fi


# ============================================================
# FINISHED
# ============================================================

echo
echo "[+] Chroot configuration completed successfully."

CHROOT_SCRIPT

  chmod 700 "$POSTINSTALL"

  # ============================================================
  # 19. VALIDATE GENERATED SCRIPT
  # ============================================================

  log "Validating generated post-install script..."

  bash -n "$POSTINSTALL"

  # ============================================================
  # 20. CHROOT
  # ============================================================

  echo
  echo "============================================================"
  echo " Configuring installed system"
  echo "============================================================"
  echo

  arch-chroot \
    /mnt \
    /root/arch-postinstall.sh

  # ============================================================
  # 21. REMOVE TEMPORARY FILES
  # ============================================================

  rm -f \
    /mnt/root/arch-postinstall.sh \
    /mnt/root/arch-install.conf

  # ============================================================
  # 22. VERIFY INSTALLATION
  # ============================================================

  echo
  echo "============================================================"
  echo " Installation verification"
  echo "============================================================"
  echo

  [[ -f /mnt/boot/grub/grub.cfg ]] ||
    die "GRUB configuration file is missing."

  [[ -d /mnt/boot/EFI/ARCH ]] ||
    die "GRUB EFI files were not found."

  [[ -f /mnt/etc/fstab ]] ||
    die "fstab is missing."

  grep -q \
    "rd.luks.name=${LUKS_UUID}=cryptroot" \
    /mnt/etc/default/grub ||
    die "LUKS kernel parameter is missing from GRUB configuration."

  log "GRUB configuration exists."
  log "EFI bootloader exists."
  log "fstab exists."
  log "LUKS boot parameters are configured."

  if [[ "$HIBERNATION" == "yes" ]]; then

    grep -q \
      "resume_offset=${SWAP_OFFSET}" \
      /mnt/etc/default/grub ||
      die "Hibernation resume offset is missing."

    log "Hibernation resume offset configured."

  fi

  # ============================================================
  # 23. SUMMARY
  # ============================================================

  sync

  echo
  echo "============================================================"
  echo "        Arch Linux installation completed successfully"
  echo "============================================================"
  echo
  echo "Root partition:"
  echo
  echo "  $ROOT_PART"
  echo
  echo "EFI partition:"
  echo
  echo "  $EFI_PART"
  echo
  echo "LUKS UUID:"
  echo
  echo "  $LUKS_UUID"
  echo
  echo "Hostname:"
  echo
  echo "  $HOSTNAME"
  echo
  echo "Timezone:"
  echo
  echo "  $TIMEZONE"
  echo
  echo "Btrfs:"
  echo
  echo "  @      -> /"
  echo "  @home  -> /home"
  echo "  @swap  -> /swap"
  echo

  if ((SWAP_SIZE > 0)); then

    echo "Swap:"
    echo
    echo "  ${SWAP_SIZE} GiB"
    echo

  fi

  if [[ "$HIBERNATION" == "yes" ]]; then

    echo "Hibernation:"
    echo
    echo "  Enabled"
    echo
    echo "Resume offset:"
    echo
    echo "  $SWAP_OFFSET"
    echo

  else

    echo "Hibernation:"
    echo
    echo "  Disabled"
    echo

  fi

  echo "Before rebooting, you may inspect:"
  echo
  echo "  cat /mnt/etc/fstab"
  echo
  echo "  cat /mnt/etc/default/grub"
  echo
  echo "  cat /mnt/etc/mkinitcpio.conf"
  echo
  echo "  ls -R /mnt/boot/EFI"
  echo
  echo "  findmnt /mnt"
  echo
  echo "  lsblk -f"
  echo

  # ============================================================
  # 24. OPTIONAL REBOOT
  # ============================================================

  if confirm "Unmount everything and reboot now?"; then

    echo

    if ((SWAP_SIZE > 0)); then

      log "Disabling swap..."

      swapoff /mnt/swap/swapfile || true

    fi

    log "Unmounting filesystems..."

    umount -R /mnt

    log "Closing LUKS container..."

    cryptsetup close cryptroot

    log "Installation complete."

    echo
    echo "Remove the Arch installation media when the system restarts."
    echo

    reboot

  else

    echo
    info "The system remains mounted at /mnt."
    echo
    echo "When ready to reboot manually:"
    echo

    if ((SWAP_SIZE > 0)); then
      echo "  swapoff /mnt/swap/swapfile"
    fi

    echo "  umount -R /mnt"
    echo "  cryptsetup close cryptroot"
    echo "  reboot"
    echo

  fi
)$()
