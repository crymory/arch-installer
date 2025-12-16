#!/usr/bin/env bash
set -e

log() { echo -e "\e[1;32m==>\e[0m $*"; }
err() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

# Проверка UEFI
[[ -d /sys/firmware/efi ]] || err "Требуется UEFI система"

log "Доступные диски:"
lsblk -d -o NAME,SIZE,TYPE | grep disk
echo ""

read -rp "Диск для установки (например sda, nvme0n1): " DISK
DISK="/dev/$DISK"
[[ -b "$DISK" ]] || err "Диск $DISK не найден"

log "Текущая разметка $DISK:"
lsblk "$DISK" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
parted "$DISK" print free
echo ""

read -rp "Размер для root раздела в GB (например 50): " SIZE_GB
[[ "$SIZE_GB" =~ ^[0-9]+$ ]] || err "Введите число"

log "Поиск EFI раздела..."
EFI_PART=$(lsblk -o NAME,PARTLABEL,TYPE "$DISK" | grep -i efi | awk '{print "/dev/"$1}' | head -1)
if [[ -z "$EFI_PART" ]]; then
    EFI_PART=$(lsblk -o NAME,FSTYPE,TYPE "$DISK" | grep vfat | awk '{print "/dev/"$1}' | head -1)
fi
[[ -z "$EFI_PART" ]] && err "EFI раздел не найден"
log "EFI: $EFI_PART"

log "Создание раздела ${SIZE_GB}GB в свободном месте..."
# Получаем следующий номер раздела
NEXT_PART_NUM=$(parted "$DISK" print | grep -E '^ [0-9]' | tail -1 | awk '{print $1+1}')
[[ -z "$NEXT_PART_NUM" ]] && NEXT_PART_NUM=2

# Создаём раздел в конце диска
parted "$DISK" --script mkpart primary ext4 -- -${SIZE_GB}GiB -0
sleep 2
partprobe "$DISK"
sleep 1

# Определяем имя нового раздела
if [[ "$DISK" =~ nvme ]]; then
    ROOT_PART="${DISK}p${NEXT_PART_NUM}"
else
    ROOT_PART="${DISK}${NEXT_PART_NUM}"
fi

[[ -b "$ROOT_PART" ]] || err "Раздел $ROOT_PART не создан"
log "Создан: $ROOT_PART"

mount | grep -q "$ROOT_PART" && err "ROOT уже смонтирован"

read -rp "⚠️ ФОРМАТИРОВАТЬ $ROOT_PART ? (yes): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && err "Отменено"

mkfs.ext4 "$ROOT_PART"
mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

log "Интернет проверка"
ping -c 2 archlinux.org >/dev/null || err "Нет интернета"

log "Установка базы"
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
GPU_PKGS="mesa"
if lspci | grep -Ei "nvidia"; then
    GPU_PKGS="nvidia nvidia-utils nvidia-settings"
    arch-chroot /mnt pacman -S --noconfirm $GPU_PKGS
elif lspci | grep -Ei "amd|radeon"; then
    GPU_PKGS="vulkan-radeon libva-mesa-driver mesa-vdpau"
    arch-chroot /mnt pacman -S --noconfirm $GPU_PKGS
elif lspci | grep -Ei "intel"; then
    GPU_PKGS="vulkan-intel intel-media-driver"
    arch-chroot /mnt pacman -S --noconfirm $GPU_PKGS
fi

log "✅ Готово! Размонтирование..."
umount -R /mnt
log "Можно делать reboot"
