#!/usr/bin/env bash
set -e

# --- Функции логирования ---
log() { echo -e "\e[1;32m==>\e[0m $*"; }
err() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }

# --- Проверка UEFI ---
[[ -d /sys/firmware/efi ]] || err "UEFI system required"

# --- Исправление проблем с интернетом и репозиториями ---
log "Checking internet connection..."
ping -c 2 8.8.8.8 >/dev/null || err "No internet connection. Please connect via iwctl."

log "Syncing system clock (needed for SSL)..."
timedatectl set-ntp true

log "Updating Arch Linux Keyring..."
# Это решает проблему 'invalid or corrupted package' при установке
pacman -Sy --noconfirm archlinux-keyring

# --- Выбор диска ---
log "Available disks:"
lsblk -d -o NAME,SIZE,TYPE | grep disk
echo ""

read -rp "Disk with main system (e.g. sda, nvme0n1): " DISK
DISK="${DISK#/dev/}"
DISK="/dev/$DISK"
[[ -b "$DISK" ]] || err "Disk $DISK not found"

# --- Выбор режима: Shrink или Reuse ---
log "Current layout $DISK:"
lsblk "$DISK" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
echo ""

read -rp "Which partition to shrink? (number, e.g. 2, or 0 to use existing): " SHRINK_NUM

# --- Функция самой установки (чтобы не дублировать код) ---
run_install() {
    local root_part=$1
    local efi_part=$2

    log "Formatting and mounting $root_part..."
    mkfs.ext4 -F "$root_part"
    mount "$root_part" /mnt
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi

    log "Installing base system (pacstrap)..."
    # Добавляем необходимые пакеты сразу
    pacstrap /mnt base linux linux-firmware sudo networkmanager vim git --noconfirm

    log "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab

    log "Configuring system inside chroot..."
    arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo arch-hypr > /etc/hostname

# Пользователь
useradd -m -G wheel anc
echo "anc:anc" | chpasswd
echo "root:anc" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

# Загрузчик
pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch-Hypr
grub-mkconfig -o /boot/grub/grub.cfg

# Hyprland и окружение
pacman -S --noconfirm hyprland xorg-xwayland mesa libinput seatd waybar rofi kitty pipewire pipewire-pulse wireplumber wl-clipboard grim slurp sddm
systemctl enable sddm seatd

# Дефолтный конфиг Hyprland (экранируем спецсимволы)
mkdir -p /home/anc/.config/hypr
cat > /home/anc/.config/hypr/hyprland.conf <<HYPR
monitor=,preferred,auto,1
\$mainMod=SUPER
bind=\$mainMod,RETURN,exec,kitty
bind=\$mainMod,D,exec,rofi -show drun
bind=\$mainMod,Q,killactive
exec-once=waybar
HYPR

chown -R anc:anc /home/anc
EOF

    log "GPU auto-detect..."
    if lspci | grep -Ei "nvidia" >/dev/null; then
        arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
    elif lspci | grep -Ei "amd|radeon" >/dev/null; then
        arch-chroot /mnt pacman -S --noconfirm vulkan-radeon libva-mesa-driver mesa-vdpau
    elif lspci | grep -Ei "intel" >/dev/null; then
        arch-chroot /mnt pacman -S --noconfirm vulkan-intel intel-media-driver
    fi

    log "✅ Done! Unmounting..."
    umount -R /mnt
    log "You can reboot now"
}

# --- Логика поиска EFI ---
find_efi() {
    local found_efi=""
    found_efi=$(lsblk -no NAME,PARTLABEL "$DISK" 2>/dev/null | grep -i "efi" | awk '{print $1}' | head -1)
    if [[ -z "$found_efi" ]]; then
        found_efi=$(lsblk -no NAME,FSTYPE "$DISK" 2>/dev/null | grep "vfat" | awk '{print $1}' | head -1)
    fi
    if [[ -z "$found_efi" ]]; then
        log "EFI not found. Available:"
        lsblk "$DISK" -o NAME,SIZE,FSTYPE
        read -rp "Enter EFI partition name (e.g. nvme0n1p1): " EFI_INPUT
        found_efi="${EFI_INPUT#/dev/}"
    fi
    echo "/dev/$found_efi"
}

# --- Сценарий 1: Использование существующего раздела ---
if [[ "$SHRINK_NUM" == "0" ]]; then
    log "Looking for existing ext4 partitions..."
    lsblk "$DISK" -o NAME,SIZE,FSTYPE | grep ext4
    read -rp "Enter partition number to reuse (e.g. 3): " REUSE_NUM
    
    [[ "$DISK" =~ nvme ]] && ROOT_P="${DISK}p${REUSE_NUM}" || ROOT_P="${DISK}${REUSE_NUM}"
    EFI_P=$(find_efi)
    
    read -rp "⚠️ FORMAT $ROOT_P and install? (yes): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && err "Cancelled"
    
    run_install "$ROOT_P" "$EFI_P"
    exit 0
fi

# --- Сценарий 2: Сжатие раздела и установка ---
[[ "$DISK" =~ nvme ]] && SHRINK_PART="${DISK}p${SHRINK_NUM}" || SHRINK_PART="${DISK}${SHRINK_NUM}"
[[ -b "$SHRINK_PART" ]] || err "Partition $SHRINK_PART not found"

FSTYPE=$(lsblk -no FSTYPE "$SHRINK_PART")
warn "⚠️  PARTITION: $SHRINK_PART ($FSTYPE)"
read -rp "How many GB to TAKE from this partition for Arch? (e.g. 50): " SIZE_GB

log "Resizing $FSTYPE filesystem..."
if [[ "$FSTYPE" == "ext4" ]]; then
    e2fsck -f "$SHRINK_PART" || true
    CUR_SIZE=$(blockdev --getsize64 "$SHRINK_PART")
    NEW_SIZE_MB=$(( (CUR_SIZE - SIZE_GB * 1024*1024*1024) / 1024/1024 ))
    resize2fs "$SHRINK_PART" ${NEW_SIZE_MB}M
elif [[ "$FSTYPE" == "ntfs" ]]; then
    which ntfsresize >/dev/null || pacman -Sy --noconfirm ntfs-3g
    CUR_SIZE=$(blockdev --getsize64 "$SHRINK_PART")
    NEW_SIZE=$((CUR_SIZE - SIZE_GB * 1024*1024*1024))
    ntfsresize -s $NEW_SIZE "$SHRINK_PART"
else
    err "Unsupported filesystem for shrinking: $FSTYPE"
fi

log "Modifying partition table..."
START=$(parted "$DISK" unit s print | grep "^ ${SHRINK_NUM} " | awk '{print $2}' | sed 's/s//')
OLD_END=$(parted "$DISK" unit s print | grep "^ ${SHRINK_NUM} " | awk '{print $3}' | sed 's/s//')
SIZE_SECTORS=$((SIZE_GB * 1024 * 1024 * 1024 / 512))
NEW_END=$((OLD_END - SIZE_SECTORS))

parted "$DISK" --script rm "${SHRINK_NUM}"
parted "$DISK" --script mkpart primary "${FSTYPE}" "${START}s" "${NEW_END}s"
parted "$DISK" --script mkpart primary ext4 "$((NEW_END + 1))s" "${OLD_END}s"

partprobe "$DISK"
sleep 2

# Находим номер нового (последнего) раздела
NEW_PART_NUM=$(parted "$DISK" print | grep -E '^ [0-9]' | tail -1 | awk '{print $1}')
[[ "$DISK" =~ nvme ]] && ROOT_P="${DISK}p${NEW_PART_NUM}" || ROOT_P="${DISK}${NEW_PART_NUM}"
EFI_P=$(find_efi)

run_install "$ROOT_P" "$EFI_P"
