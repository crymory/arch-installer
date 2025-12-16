#!/usr/bin/env bash
set -e

log() { echo -e "\e[1;32m==>\e[0m $*"; }
err() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }

# Check UEFI
[[ -d /sys/firmware/efi ]] || err "UEFI system required"

log "Available disks:"
lsblk -d -o NAME,SIZE,TYPE | grep disk
echo ""

read -rp "Disk with main system (e.g. sda, nvme0n1): " DISK
# Remove /dev/ if user added it
DISK="${DISK#/dev/}"
DISK="/dev/$DISK"
[[ -b "$DISK" ]] || err "Disk $DISK not found"

log "Current layout $DISK:"
lsblk "$DISK" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
echo ""

log "Partitions:"
parted "$DISK" unit GiB print
echo ""

read -rp "Which partition to shrink? (number, e.g. 2, or 0 to use existing): " SHRINK_NUM

# Check if user wants to reuse existing partition
if [[ "$SHRINK_NUM" == "0" ]]; then
    log "Looking for existing ext4 partitions..."
    lsblk "$DISK" -o NAME,SIZE,FSTYPE | grep ext4
    echo ""
    read -rp "Enter partition number to reuse (e.g. 3): " REUSE_NUM
    
    if [[ "$DISK" =~ nvme ]]; then
        ROOT_PART="${DISK}p${REUSE_NUM}"
    else
        ROOT_PART="${DISK}${REUSE_NUM}"
    fi
    
    [[ -b "$ROOT_PART" ]] || err "Partition $ROOT_PART not found"
    
    read -rp "⚠️ FORMAT $ROOT_PART and install Arch? (yes): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && err "Cancelled"
    
    log "Finding EFI partition..."
    # Try multiple methods to find EFI
    EFI_PART=$(lsblk -o NAME,PARTLABEL,FSTYPE "$DISK" | grep -i efi | awk '{print "/dev/"$1}' | head -1)
    if [[ -z "$EFI_PART" ]]; then
        EFI_PART=$(lsblk -o NAME,FSTYPE "$DISK" | grep vfat | awk '{print "/dev/"$1}' | head -1)
    fi
    if [[ -z "$EFI_PART" ]]; then
        # Show all partitions and let user choose
        log "Auto-detect failed. Available partitions:"
        lsblk "$DISK" -o NAME,SIZE,FSTYPE,PARTLABEL
        read -rp "Enter EFI partition (e.g. nvme0n1p1): " EFI_INPUT
        EFI_INPUT="${EFI_INPUT#/dev/}"
        EFI_PART="/dev/$EFI_INPUT"
    fi
    [[ -b "$EFI_PART" ]] || err "EFI partition $EFI_PART not found"
    log "EFI: $EFI_PART"
    
    mkfs.ext4 "$ROOT_PART"
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
    
    # Skip to installation
    SKIP_PARTITION=true
fi

[[ "$SKIP_PARTITION" == "true" ]] && {
    log "Internet check"
    ping -c 2 archlinux.org >/dev/null || err "No internet connection"
    log "Installing base system"
    pacstrap /mnt base linux linux-firmware sudo networkmanager vim git
    genfstab -U /mnt >> /mnt/etc/fstab
    
    arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo arch-hypr > /etc/hostname

useradd -m -G wheel anc
echo "anc:anc" | chpasswd
echo "root:anc" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch-Hypr
grub-mkconfig -o /boot/grub/grub.cfg

pacman -S --noconfirm \\
  hyprland xorg-xwayland mesa libinput seatd \\
  waybar rofi kitty \\
  pipewire pipewire-pulse wireplumber \\
  wl-clipboard grim slurp \\
  sddm

systemctl enable sddm seatd

mkdir -p /home/anc/.config/hypr
cat > /home/anc/.config/hypr/hyprland.conf <<HYPR
monitor=,preferred,auto,1
\\\$mainMod=SUPER
bind=\\\$mainMod,RETURN,exec,kitty
bind=\\\$mainMod,D,exec,rofi -show drun
bind=\\\$mainMod,Q,killactive
exec-once=waybar
HYPR

chown -R anc:anc /home/anc
EOF

    log "GPU auto-detect..."
    if lspci | grep -Ei "nvidia"; then
        arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
    elif lspci | grep -Ei "amd|radeon"; then
        arch-chroot /mnt pacman -S --noconfirm vulkan-radeon libva-mesa-driver mesa-vdpau
    elif lspci | grep -Ei "intel"; then
        arch-chroot /mnt pacman -S --noconfirm vulkan-intel intel-media-driver
    fi

    log "✅ Done! Unmounting..."
    umount -R /mnt
    log "You can reboot now"
    exit 0
}

# Continue with shrinking if not skipped
SHRINK_PART="${DISK}${SHRINK_NUM}"
[[ "$DISK" =~ nvme ]] && SHRINK_PART="${DISK}p${SHRINK_NUM}"
[[ -b "$SHRINK_PART" ]] || err "Partition $SHRINK_PART not found"

# Get filesystem type
FSTYPE=$(lsblk -no FSTYPE "$SHRINK_PART")
[[ -z "$FSTYPE" ]] && err "Cannot detect filesystem"

warn "⚠️  PARTITION: $SHRINK_PART ($FSTYPE)"
warn "⚠️  BACKUP YOUR DATA BEFORE RESIZING!"
echo ""

read -rp "How many GB to TAKE from $SHRINK_PART for Arch? (e.g. 50): " SIZE_GB
[[ "$SIZE_GB" =~ ^[0-9]+$ ]] || err "Enter a number"

read -rp "⚠️ SHRINK $SHRINK_PART by ${SIZE_GB}GB? (yes): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && err "Cancelled"

log "Checking and resizing partition..."

case "$FSTYPE" in
    ext4|ext3|ext2)
        # For ext4: check and resize2fs
        e2fsck -f "$SHRINK_PART" || warn "Errors fixed"
        
        # Get current size in bytes
        CURRENT_SIZE=$(blockdev --getsize64 "$SHRINK_PART")
        NEW_SIZE=$((CURRENT_SIZE - SIZE_GB * 1024 * 1024 * 1024))
        NEW_SIZE_MB=$((NEW_SIZE / 1024 / 1024))
        
        resize2fs "$SHRINK_PART" ${NEW_SIZE_MB}M
        ;;
    
    ntfs)
        # For NTFS (Windows)
        which ntfsresize >/dev/null || err "Install ntfs-3g: pacman -S ntfs-3g"
        
        CURRENT_SIZE=$(blockdev --getsize64 "$SHRINK_PART")
        NEW_SIZE=$((CURRENT_SIZE - SIZE_GB * 1024 * 1024 * 1024))
        
        ntfsresize -n -s $NEW_SIZE "$SHRINK_PART" || err "ntfsresize pre-check failed"
        ntfsresize -s $NEW_SIZE "$SHRINK_PART"
        ;;
    
    *)
        err "Unsupported filesystem: $FSTYPE (supported: ext4/ntfs)"
        ;;
esac

log "Shrinking partition in partition table..."

# Get partition start
START=$(parted "$DISK" unit s print | grep "^ ${SHRINK_NUM} " | awk '{print $2}' | sed 's/s//')
CURRENT_END=$(parted "$DISK" unit s print | grep "^ ${SHRINK_NUM} " | awk '{print $3}' | sed 's/s//')

# New partition end
SIZE_SECTORS=$((SIZE_GB * 1024 * 1024 * 1024 / 512))
NEW_END=$((CURRENT_END - SIZE_SECTORS))

# Remove and recreate partition with new size
parted "$DISK" --script rm ${SHRINK_NUM}
parted "$DISK" --script mkpart primary ${FSTYPE} ${START}s ${NEW_END}s

partprobe "$DISK"
sleep 2

log "Creating new partition for Arch..."

# Next partition number
NEXT_PART_NUM=$(parted "$DISK" print | grep -E '^ [0-9]' | tail -1 | awk '{print $1+1}')

# Create Arch partition right after shrinked one
ARCH_START=$((NEW_END + 1))
ARCH_END=$((ARCH_START + SIZE_SECTORS))

parted "$DISK" --script mkpart primary ext4 ${ARCH_START}s ${ARCH_END}s

partprobe "$DISK"
sleep 2

if [[ "$DISK" =~ nvme ]]; then
    ROOT_PART="${DISK}p${NEXT_PART_NUM}"
else
    ROOT_PART="${DISK}${NEXT_PART_NUM}"
fi

[[ -b "$ROOT_PART" ]] || err "Partition $ROOT_PART not created"
log "Created Arch partition: $ROOT_PART"

log "Finding EFI partition..."
# Try multiple methods to find EFI
EFI_PART=$(lsblk -o NAME,PARTLABEL,FSTYPE "$DISK" | grep -i efi | awk '{print "/dev/"$1}' | head -1)
if [[ -z "$EFI_PART" ]]; then
    EFI_PART=$(lsblk -o NAME,FSTYPE "$DISK" | grep vfat | awk '{print "/dev/"$1}' | head -1)
fi
if [[ -z "$EFI_PART" ]]; then
    # Show all partitions and let user choose
    log "Auto-detect failed. Available partitions:"
    lsblk "$DISK" -o NAME,SIZE,FSTYPE,PARTLABEL
    read -rp "Enter EFI partition (e.g. nvme0n1p1): " EFI_INPUT
    EFI_INPUT="${EFI_INPUT#/dev/}"
    EFI_PART="/dev/$EFI_INPUT"
fi
[[ -b "$EFI_PART" ]] || err "EFI partition $EFI_PART not found"
log "EFI: $EFI_PART"

mkfs.ext4 "$ROOT_PART"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

log "Internet check"
ping -c 2 archlinux.org >/dev/null || err "No internet connection"

log "Installing base system"
pacstrap /mnt base linux linux-firmware sudo networkmanager vim git

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
set -e
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo arch-hypr > /etc/hostname

useradd -m -G wheel anc
echo "anc:anc" | chpasswd
echo "root:anc" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

pacman -S --noconfirm grub efibootmgr
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch-Hypr
grub-mkconfig -o /boot/grub/grub.cfg

pacman -S --noconfirm \\
  hyprland xorg-xwayland mesa libinput seatd \\
  waybar rofi kitty \\
  pipewire pipewire-pulse wireplumber \\
  wl-clipboard grim slurp \\
  sddm

systemctl enable sddm seatd

mkdir -p /home/anc/.config/hypr
cat > /home/anc/.config/hypr/hyprland.conf <<HYPR
monitor=,preferred,auto,1
\\\$mainMod=SUPER
bind=\\\$mainMod,RETURN,exec,kitty
bind=\\\$mainMod,D,exec,rofi -show drun
bind=\\\$mainMod,Q,killactive
exec-once=waybar
HYPR

chown -R anc:anc /home/anc
EOF

log "GPU auto-detect..."
if lspci | grep -Ei "nvidia"; then
    arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
elif lspci | grep -Ei "amd|radeon"; then
    arch-chroot /mnt pacman -S --noconfirm vulkan-radeon libva-mesa-driver mesa-vdpau
elif lspci | grep -Ei "intel"; then
    arch-chroot /mnt pacman -S --noconfirm vulkan-intel intel-media-driver
fi

log "✅ Done! Unmounting..."
umount -R /mnt
log "You can reboot now"
