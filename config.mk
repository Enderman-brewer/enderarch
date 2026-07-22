# Enderarch build configuration
# Architecture targets
ARCHS_X86_64 := x86_64
ARCHS_ARM64 := arm64

# Kernel packages (Arch Linux names)
KERNEL_X86_64 := linux linux-lts
KERNEL_ARM64 := linux-aarch64 linux-lts-aarch64

# Kernel image filenames
KERNEL_IMG_linux := vmlinuz-linux
KERNEL_IMG_linux-lts := vmlinuz-linux-lts
KERNEL_IMG_linux-aarch64 := vmlinuz-linux-aarch64
KERNEL_IMG_linux-lts-aarch64 := vmlinuz-linux-lts-aarch64

# Initrd filenames
INITRD_COMMON := initramfs-common.img
INITRD_ENDERARCH := initramfs-enderarch.img
INITRD_ENDERLOADER := initramfs-enderloader.img

# mkinitcpio preset files
MKINITCPIO_COMMON := mkinitcpio-common.conf
MKINITCPIO_ENDERARCH := mkinitcpio-enderarch.conf
MKINITCPIO_ENDERLOADER := mkinitcpio-enderloader.conf

# Pacman
PACMAN_CONF := /etc/pacman.conf
PACMAN_STRAP := pacstrap -c -G -M

# Squashfs
SQUASHFS_COMP := zstd -Xcompression-level 15

# ISO
ISONAME := enderarch
ISO_DIR := $(CURDIR)/iso
OUT_DIR := $(CURDIR)/out
PROFILES_DIR := $(CURDIR)/profiles
OVERLAY_DIR := $(CURDIR)/overlay
SCRIPTS_DIR := $(CURDIR)/scripts
MKINITCPIO_DIR := $(CURDIR)/mkinitcpio
GRUB_DIR := $(CURDIR)/grub

DATE := $(shell date +%Y%m%d)
