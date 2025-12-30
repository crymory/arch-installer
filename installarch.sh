#!/usr/bin/env bash
set -e

log() { echo -e "\e[1;32m==>\e[0m $*"; }
err() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }

[[ -d /sys/firmware/efi ]] || err "UEFI system required"

log "Checking internet connection..."
ping -c 2 8.8.8.8 >/dev/null || err "No internet connection. Connect via iwctl."

log "Syncing system clock and updating keyring..."
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring

log "Available disks:"
lsblk -d -o NAME,SIZE,TYPE | grep disk
echo ""

read -rp "Disk with main system (e.g. nvme0n1): " DISK
DISK="${DISK#/dev/}"
DISK="/dev/$DISK"
[[ -b "$DISK" ]] || err "Disk $DISK not found"

# Функция установки
run_install() {
    local root_part=$1
    local efi_part=$2

    log "Target Root: $root_part"
    log "Target EFI:  $efi_part"

    log "Formatting $root_part as ext4..."
    mkfs.ext4 -F "$root_part"
    
    log "Mounting..."
    mount "$root_part" /mnt
    mkdir -p /mnt/boot/efi
    mount "$efi_part" /mnt/boot/efi || err "Failed to mount EFI partition $efi_part"

    log "Installing base system..."
    pacstrap /mnt base linux linux-firmware sudo networkmanager vim git --noconfirm

    genfstab -U /mnt >> /mnt/etc/fstab

    log "Entering chroot..."
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

pacman -S --noconfirm hyprland xorg-xwayland mesa libinput seatd waybar rofi kitty pipewire pipewire-pulse wireplumber wl-clipboard grim slurp sddm
systemctl enable sddm seatd

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

    log "GPU check..."
    if lspci | grep -Ei "nvidia" >/dev/null; then
        arch-chroot /mnt pacman -S --noconfirm nvidia nvidia-utils nvidia-settings
    elif lspci | grep -Ei "amd|radeon" >/dev/null; then
        arch-chroot /mnt pacman -S --noconfirm vulkan-radeon libva-mesa-driver mesa-vdpau
    elif lspci | grep -Ei "intel" >/dev/null; then
        arch-chroot /mnt pacman -S --noconfirm vulkan-intel intel-media-driver
    fi

    log "✅ Done! Unmount and reboot."
    umount -R /mnt
}

# Вывод разметки для пользователя
log "Current partitions on $DISK:"
lsblk "$DISK" -o NAME,SIZE,FSTYPE,PARTLABEL

read -rp "Which partition for Arch (Root)? (number, e.g. 5): " ROOT_NUM
[[ "$DISK" =~ nvme ]] && ROOT_P="${DISK}p${ROOT_NUM}" || ROOT_P="${DISK}${ROOT_NUM}"

read -rp "Which partition for EFI? (number, e.g. 1): " EFI_NUM
[[ "$DISK" =~ nvme ]] && EFI_P="${DISK}p${EFI_NUM}" || EFI_P="${DISK}${EFI_NUM}"

[[ -b "$ROOT_P" ]] || err "Root partition $ROOT_P not found"
[[ -b "$EFI_P" ]] || err "EFI partition $EFI_P not found"

read -rp "⚠️  Format $ROOT_P and install? (yes): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || err "Cancelled"

run_install "$ROOT_P" "$EFI_P"
