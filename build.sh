#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Argument parsing ---
FLAVOR=""
START_PHASE=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-phase|--from)
            START_PHASE="${2:?Missing phase number}"
            shift 2
            continue
            ;;
        -h|--help)
            echo "Usage: $0 <flavor> [--from-phase N]"
            echo ""
            echo "  flavor:     vanilla | kgui | mingui"
            echo "  --from-phase N  Start from phase N (1-6):"
            echo "    1 = pacstrap + users (slow, requires network)"
            echo "    2 = overlay + squashfs"
            echo "    3 = x86_64 initrds"
            echo "    4 = ARM64 initrds"
            echo "    5 = stage ISO files"
            echo "    6 = generate ISO"
            exit 0
            ;;
        *)
            [[ -z "$FLAVOR" ]] || { echo "Unknown argument: $1"; exit 1; }
            FLAVOR="$1"
            shift
            ;;
    esac
done
: "${FLAVOR:?Usage: $0 <flavor> [--from-phase N]}"
[[ "$START_PHASE" =~ ^[1-6]$ ]] || { echo "Error: --from-phase must be 1-6"; exit 1; }

# ------------------------------------------------------------------
# Build configuration (mirrors config.mk for Make compatibility)
# ------------------------------------------------------------------
KERNEL_X86_64="linux linux-lts"
KERNEL_ARM64="linux-aarch64 linux-lts-aarch64"

INITRD_COMMON="initramfs-common.img"
INITRD_ENDERARCH="initramfs-enderarch.img"
INITRD_ENDERLOADER="initramfs-enderloader.img"

CURDIR="${SCRIPT_DIR}"
ISO_DIR="${SCRIPT_DIR}/iso"
OUT_DIR="${SCRIPT_DIR}/out"
PROFILES_DIR="${SCRIPT_DIR}/profiles"
OVERLAY_DIR="${SCRIPT_DIR}/overlay"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
MKINITCPIO_DIR="${SCRIPT_DIR}/mkinitcpio"
GRUB_DIR="${SCRIPT_DIR}/grub"
DATE="$(date +%Y%m%d)"

WORKDIR="${SCRIPT_DIR}/workdir-${FLAVOR}"
ROOTFS_SFS="${ISO_DIR}/LiveOS/rootfs.sfs"
ISONAME_FULL="enderarch-${FLAVOR}-${DATE}"

# ------------------------------------------------------------------
# Helper: return the vmlinuz image filename for a given kernel package
# ------------------------------------------------------------------
kernel_image_name() {
    local pkg="$1"
    echo "vmlinuz-${pkg}"
}

# ------------------------------------------------------------------
# Clean and create working directory (skip if --from-phase > 1)
# ------------------------------------------------------------------
if [[ $START_PHASE -le 1 ]]; then
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
else
    echo "==> Skipping workdir cleanup (--from-phase=$START_PHASE)"
    mkdir -p "$WORKDIR"
fi

# Ensure the ISO staging skeleton exists
mkdir -p "${ISO_DIR}/boot/x86_64" \
         "${ISO_DIR}/boot/arm64" \
         "${ISO_DIR}/boot/grub" \
         "${ISO_DIR}/EFI/BOOT" \
         "${ISO_DIR}/isolinux" \
         "${ISO_DIR}/LiveOS" \
         "${OUT_DIR}"

# ------------------------------------------------------------------
# Check required tools
# ------------------------------------------------------------------
REQUIRED_CMDS=(pacstrap arch-chroot mksquashfs mkinitcpio xorriso)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required tool '$cmd' not found. Please install it."
        exit 1
    fi
done

# ==================================================================
# Phase 1: Installing base system (x86_64)
# ==================================================================
echo "==> Phase 1: Installing base system (x86_64)"
if [[ $START_PHASE -le 1 ]]; then

PKG_FILE="${PROFILES_DIR}/${FLAVOR}/packages.x86_64"
if [[ ! -f "$PKG_FILE" ]]; then
    echo "Error: Package list not found: $PKG_FILE"
    exit 1
fi

# Read package list, skipping blank lines and comments
PACKAGES=()
while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    # Strip leading/trailing whitespace
    pkg="${pkg## }"
    pkg="${pkg%% }"
    [[ -z "$pkg" ]] && continue
    [[ "$pkg" =~ ^# ]] && continue
    PACKAGES+=("$pkg")
done < "$PKG_FILE"

# Append kernel packages from config
for kpkg in ${KERNEL_X86_64}; do
    PACKAGES+=("$kpkg")
done

echo "    Installing packages: ${PACKAGES[*]}"
pacstrap -c -G -M "$WORKDIR" "${PACKAGES[@]}" < /dev/null

echo "    Configuring users..."
arch-chroot "$WORKDIR" useradd -m -G wheel ender
arch-chroot "$WORKDIR" sh -c "echo 'root:arch' | chpasswd"
arch-chroot "$WORKDIR" sh -c "echo 'ender:arch' | chpasswd"

fi
# ==================================================================
# Phase 1b: Copying overlay files
# ==================================================================
echo "==> Phase 1b: Copying overlay files"
if [[ $START_PHASE -le 2 ]]; then

OVERLAY_SRC="${OVERLAY_DIR}/common"
if [[ -d "$OVERLAY_SRC" ]]; then
    echo "    Copying overlay/common -> workdir"
    cp -af "$OVERLAY_SRC"/. "$WORKDIR/"
fi

OVERLAY_FLAVOR="${OVERLAY_DIR}/${FLAVOR}"
if [[ -d "$OVERLAY_FLAVOR" ]]; then
    echo "    Copying overlay/${FLAVOR} -> workdir"
    cp -af "$OVERLAY_FLAVOR"/. "$WORKDIR/"
fi

# Enable systemd services
echo "    Enabling systemd services..."
arch-chroot "$WORKDIR" systemctl enable NetworkManager.service 2>/dev/null || true
case "$FLAVOR" in
    kgui)
        arch-chroot "$WORKDIR" systemctl enable sddm.service 2>/dev/null || true
        echo "    SDDM enabled for KGUI"
        ;;
    mingui)
        arch-chroot "$WORKDIR" systemctl enable lightdm.service 2>/dev/null || true
        echo "    LightDM enabled for MinGUI"
        ;;
esac

fi
# ==================================================================
# Phase 2: Creating squashfs
# ==================================================================
echo "==> Phase 2: Creating squashfs"
if [[ $START_PHASE -le 2 ]]; then

rm -f "$ROOTFS_SFS"
echo "    Running mksquashfs (this may take a while)..."
mksquashfs "$WORKDIR" "$ROOTFS_SFS" -comp zstd -Xcompression-level 15

fi
# ==================================================================
# Phase 3: Building x86_64 initrds
# ==================================================================
echo "==> Phase 3: Building x86_64 initrds"
if [[ $START_PHASE -le 3 ]]; then

shopt -s nullglob
PRESETS=( "${PROFILES_DIR}/${FLAVOR}/mkinitcpio-"*.conf )
shopt -u nullglob

if [[ ${#PRESETS[@]} -eq 0 ]]; then
    echo "    Warning: No mkinitcpio preset files found in profiles/${FLAVOR}/"
    echo "    Skipping initrd builds."
else
    # Copy custom hooks into workdir so mkinitcpio can find them in-chroot
    mkdir -p "${WORKDIR}/usr/lib/initcpio/install" "${WORKDIR}/usr/lib/initcpio/hooks"
    cp "${MKINITCPIO_DIR}/install/"* "${WORKDIR}/usr/lib/initcpio/install/"
    cp "${MKINITCPIO_DIR}/hooks/"* "${WORKDIR}/usr/lib/initcpio/hooks/"

    # Stage common init scripts into workdir
    echo "    Staging init scripts into workdir..."
    mkdir -p "${WORKDIR}/lib/enderarch" \
             "${WORKDIR}/mnt/enderarch/cow/work" \
             "${WORKDIR}/mnt/enderarch/cow/upper"
    cp "${SCRIPTS_DIR}/init-common" "${WORKDIR}/init"
    cp "${SCRIPTS_DIR}/setup-binfmt" "${WORKDIR}/lib/enderarch/"
    cp "${SCRIPTS_DIR}/find-squashfs" "${WORKDIR}/lib/enderarch/"
    cp "${SCRIPTS_DIR}/setup-overlay" "${WORKDIR}/lib/enderarch/"
    cp "${SCRIPTS_DIR}/enderarch-scan" "${WORKDIR}/lib/enderarch/"
    # Register x86_64 emulator for ARM boot (if available)
    cp "/usr/bin/qemu-x86_64-static" "${WORKDIR}/usr/bin/" 2>/dev/null || true

    # Detect installed kernel versions in workdir for -k flag
    KERNEL_VERSIONS=( $(ls "${WORKDIR}/usr/lib/modules/" 2>/dev/null | sort -V) )
    if [[ ${#KERNEL_VERSIONS[@]} -eq 0 ]]; then
        echo "    ERROR: No kernel modules found in ${WORKDIR}/usr/lib/modules/"
        exit 1
    fi
    # Use the first (newest) kernel version for mkinitcpio's -k flag.
    # Our custom hooks add modules from ALL kernels regardless.
    KERNEL_VER="${KERNEL_VERSIONS[-1]}"
    echo "    Using kernel version: ${KERNEL_VER}"

    for preset in "${PRESETS[@]}"; do
        base="$(basename "$preset")"          # mkinitcpio-common.conf
        name="${base#mkinitcpio-}"            # common.conf
        name="${name%.conf}"                  # common
        name_upper="${name^^}"                # COMMON
        output_var="INITRD_${name_upper}"

        # Use indirect expansion; fall back to a derived filename
        if [[ -n "${!output_var:-}" ]]; then
            output_name="${!output_var}"
        else
            output_name="initramfs-${name}.img"
        fi

        output_path="${ISO_DIR}/boot/x86_64/${output_name}"

        # Copy preset into workdir for in-chroot mkinitcpio
        cp "$preset" "${WORKDIR}/etc/${base}"

        # Swap init-mode for this initrd type
        rm -f "${WORKDIR}/lib/enderarch/init-mode"
        case "$name" in
            common)
                echo "    (common initrd uses /init - no init-mode needed)"
                ;;
            enderarch)
                cp "${SCRIPTS_DIR}/init-enderarch" "${WORKDIR}/lib/enderarch/init-mode"
                ;;
            enderloader)
                cp "${SCRIPTS_DIR}/init-enderloader" "${WORKDIR}/lib/enderarch/init-mode"
                cp -a "${OVERLAY_DIR}/enderloader/mnt/enderloader/." \
                   "${WORKDIR}/mnt/enderloader/" 2>/dev/null || true
                cp "${SCRIPTS_DIR}/88-enderloader.sh" "${WORKDIR}/etc/profile.d/" 2>/dev/null || true
                ;;
        esac

        echo "    Building initrd: ${output_name}"
        # Run mkinitcpio inside the chroot so it finds modules + binaries
        arch-chroot "$WORKDIR" /usr/bin/mkinitcpio -k "${KERNEL_VER}" -c "/etc/${base}" -g "/boot/${output_name}" 2>&1 || {
            echo "    ERROR: initrd build for ${name} failed!"
            exit 1
        }
        # Copy result from chroot's /boot to ISO staging
        if [[ -f "${WORKDIR}/boot/${output_name}" ]]; then
            cp "${WORKDIR}/boot/${output_name}" "$output_path"
            echo "    Copied ${output_name} to ISO staging"
        else
            echo "    ERROR: ${output_name} not found in chroot /boot/"
            exit 1
        fi
    done
fi

# Copy kernel images into the ISO staging area
echo "    Copying x86_64 kernel images..."
for kpkg in ${KERNEL_X86_64}; do
    img_name="$(kernel_image_name "$kpkg")"
    src="${WORKDIR}/boot/${img_name}"
    if [[ -f "$src" ]]; then
        cp -a "$src" "${ISO_DIR}/boot/x86_64/${img_name}"
        echo "      Copied ${img_name}"
    else
        echo "      Warning: kernel image not found at ${src}"
    fi
done

fi
# ==================================================================
# Phase 4: Building ARM64 initrds (if available)
# ==================================================================
echo "==> Phase 4: Building ARM64 initrds (if available)"
if [[ $START_PHASE -le 4 ]]; then

if command -v qemu-aarch64-static &>/dev/null; then
    ARM_WORKDIR="${SCRIPT_DIR}/workdir-${FLAVOR}-arm"
    ARM_PKG_FILE="${PROFILES_DIR}/${FLAVOR}/packages.aarch64"

    if [[ -f "$ARM_PKG_FILE" ]]; then
        echo "    qemu-aarch64-static detected. Bootstrapping ARM64 root..."

        rm -rf "$ARM_WORKDIR"
        mkdir -p "$ARM_WORKDIR"

        # Read ARM64 package list
        ARM_PACKAGES=()
        while IFS= read -r pkg || [[ -n "$pkg" ]]; do
            pkg="${pkg## }"
            pkg="${pkg%% }"
            [[ -z "$pkg" ]] && continue
            [[ "$pkg" =~ ^# ]] && continue
            ARM_PACKAGES+=("$pkg")
        done < "$ARM_PKG_FILE"

        for kpkg in ${KERNEL_ARM64}; do
            ARM_PACKAGES+=("$kpkg")
        done

        echo "    Installing ARM64 packages: ${ARM_PACKAGES[*]}"
        pacstrap -c -G -M "$ARM_WORKDIR" "${ARM_PACKAGES[@]}" < /dev/null

        # Register qemu-aarch64-static in the chroot so arch-chroot works
        mkdir -p "$ARM_WORKDIR/usr/bin"
        cp "$(command -v qemu-aarch64-static)" "$ARM_WORKDIR/usr/bin/"

        # Copy mkinitcpio configs and hooks into the ARM chroot
        mkdir -p "${ARM_WORKDIR}/etc/mkinitcpio.d" \
                 "${ARM_WORKDIR}/usr/lib/initcpio/install" \
                 "${ARM_WORKDIR}/usr/lib/initcpio/hooks"
        cp "${MKINITCPIO_DIR}/install/"* "${ARM_WORKDIR}/usr/lib/initcpio/install/"
        cp "${MKINITCPIO_DIR}/hooks/"* "${ARM_WORKDIR}/usr/lib/initcpio/hooks/"

        # Copy init scripts into the ARM chroot (stage for mkinitcpio)
        mkdir -p "${ARM_WORKDIR}/lib/enderarch" "${ARM_WORKDIR}/mnt/enderarch"
        # Common init
        cp "${SCRIPTS_DIR}/init-common" "${ARM_WORKDIR}/init"
        cp "${SCRIPTS_DIR}/setup-binfmt" "${ARM_WORKDIR}/lib/enderarch/"
        cp "${SCRIPTS_DIR}/find-squashfs" "${ARM_WORKDIR}/lib/enderarch/"
        cp "${SCRIPTS_DIR}/enderarch-scan" "${ARM_WORKDIR}/lib/enderarch/"
        # Register x86_64 emulator for ARM boot
        cp "/usr/bin/qemu-x86_64-static" "${ARM_WORKDIR}/usr/bin/" 2>/dev/null || true

        # Detect ARM kernel version for -k flag
        ARM_KERNEL_VERSIONS=( $(ls "${ARM_WORKDIR}/usr/lib/modules/" 2>/dev/null | sort -V) )
        if [[ ${#ARM_KERNEL_VERSIONS[@]} -eq 0 ]]; then
            echo "    Skipping ARM64: no kernel modules found"
        else
            ARM_KERNEL_VER="${ARM_KERNEL_VERSIONS[-1]}"
            echo "    Using ARM kernel version: ${ARM_KERNEL_VER}"

            # Build ARM64 initrds using the same mkinitcpio presets
            shopt -s nullglob
            ARM_PRESETS=( "${PROFILES_DIR}/${FLAVOR}/mkinitcpio-"*.conf )
            shopt -u nullglob

            for preset in "${ARM_PRESETS[@]}"; do
                base="$(basename "$preset")"
                name="${base#mkinitcpio-}"
                name="${name%.conf}"
                name_upper="${name^^}"
                output_var="INITRD_${name_upper}"

                if [[ -n "${!output_var:-}" ]]; then
                    output_name="${!output_var}"
                else
                    output_name="initramfs-${name}.img"
                fi

                output_path="${ISO_DIR}/boot/arm64/${output_name}"

                # Stage correct init-mode for this initrd type
                rm -f "${ARM_WORKDIR}/lib/enderarch/init-mode"
                case "$name" in
                    common)
                        # init-common is already staged as /init above
                        ;;
                    enderarch)
                        cp "${SCRIPTS_DIR}/init-enderarch" "${ARM_WORKDIR}/lib/enderarch/init-mode"
                        cp "${SCRIPTS_DIR}/setup-overlay" "${ARM_WORKDIR}/lib/enderarch/"
                        ;;
                    enderloader)
                        cp "${SCRIPTS_DIR}/init-enderloader" "${ARM_WORKDIR}/lib/enderarch/init-mode"
                        cp "${SCRIPTS_DIR}/enderarch-scan" "${ARM_WORKDIR}/lib/enderarch/"
                        cp -a "${OVERLAY_DIR}/enderloader/mnt/enderloader/." \
                           "${ARM_WORKDIR}/mnt/enderloader/" 2>/dev/null || true
                        ;;
                esac

                echo "    Building ARM64 initrd: ${output_name}"
                cp "$preset" "${ARM_WORKDIR}/etc/${base}"
                arch-chroot "$ARM_WORKDIR" /usr/bin/mkinitcpio -k "${ARM_KERNEL_VER}" -c "/etc/${base}" -g "/boot/${output_name}" 2>&1 || {
                    echo "    Warning: ARM64 initrd build for ${name} failed (see above)"
                }
                if [[ -f "${ARM_WORKDIR}/boot/${output_name}" ]]; then
                    cp "${ARM_WORKDIR}/boot/${output_name}" "$output_path"
                fi
            done
        fi

        # Copy ARM64 kernel images
        echo "    Copying ARM64 kernel images..."
        for kpkg in ${KERNEL_ARM64}; do
            img_name="$(kernel_image_name "$kpkg")"
            src="${ARM_WORKDIR}/boot/${img_name}"
            if [[ -f "$src" ]]; then
                cp -a "$src" "${ISO_DIR}/boot/arm64/${img_name}"
                echo "      Copied ${img_name}"
            else
                echo "      Warning: ARM64 kernel image not found at ${src}"
            fi
        done

        # Clean up ARM workdir
        rm -rf "$ARM_WORKDIR"
    else
        echo "    Skipping ARM64: no packages.aarch64 found for flavor '${FLAVOR}'"
    fi
else
    echo "    Skipping ARM64: qemu-aarch64-static not available on this host"
fi

fi
# ==================================================================
# Phase 5: Staging ISO files
# ==================================================================
echo "==> Phase 5: Staging ISO files"
if [[ $START_PHASE -le 5 ]]; then

# -- GRUB modules (copied from the host system) --
if [[ -d "/usr/lib/grub" ]]; then
    echo "    Copying GRUB modules from host..."
    for arch in x86_64-efi arm64-efi i386-pc; do
        src="/usr/lib/grub/${arch}"
        if [[ -d "$src" ]]; then
            cp -a "$src" "${ISO_DIR}/boot/grub/" 2>/dev/null || true
            echo "      Copied ${arch}"
        fi
    done
fi

# -- GRUB configuration (substitute flavor placeholder) --
GRUB_CFG_SRC="${GRUB_DIR}/grub.cfg.in"
GRUB_CFG_DST="${ISO_DIR}/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG_SRC" ]]; then
    echo "    Generating grub.cfg for flavor '${FLAVOR}'"
    sed 's/${FLAVOR}/'"${FLAVOR}"'/g' "$GRUB_CFG_SRC" > "$GRUB_CFG_DST"
    echo "    Generated grub.cfg"
fi

# -- EFI boot executables (standalone GRUB images) --
# x86_64
if [[ -f "/usr/lib/grub/x86_64-efi/grub.efi" ]]; then
    cp "/usr/lib/grub/x86_64-efi/grub.efi" "${ISO_DIR}/EFI/BOOT/BOOTx64.EFI"
    echo "    Copied BOOTx64.EFI"
elif command -v grub-mkstandalone &>/dev/null; then
    echo "    Building BOOTx64.EFI with grub-mkstandalone..."
    grub-mkstandalone -O x86_64-efi \
        -o "${ISO_DIR}/EFI/BOOT/BOOTx64.EFI" \
        "boot/grub/grub.cfg=${GRUB_DIR}/grub.cfg" 2>/dev/null || true
    if [[ -f "${ISO_DIR}/EFI/BOOT/BOOTx64.EFI" ]]; then
        echo "    Built BOOTx64.EFI"
    fi
fi

# ARM64
if [[ -f "/usr/lib/grub/arm64-efi/grub.efi" ]]; then
    cp "/usr/lib/grub/arm64-efi/grub.efi" "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI"
    echo "    Copied BOOTAA64.EFI"
elif command -v grub-mkstandalone &>/dev/null; then
    echo "    Building BOOTAA64.EFI with grub-mkstandalone..."
    grub-mkstandalone -O arm64-efi \
        -o "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" \
        "boot/grub/grub.cfg=${GRUB_DIR}/grub.cfg" 2>/dev/null || true
    if [[ -f "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" ]]; then
        echo "    Built BOOTAA64.EFI"
    fi
fi

# -- Isolinux / BIOS boot files --
if [[ -d "/usr/lib/syslinux/bios" ]]; then
    echo "    Copying isolinux files from host..."
    for f in isolinux.bin ldlinux.c32 mboot.c32 vesamenu.c32 libcom32.c32 libutil.c32; do
        src="/usr/lib/syslinux/bios/${f}"
        if [[ -f "$src" ]]; then
            cp "$src" "${ISO_DIR}/isolinux/" 2>/dev/null || true
        fi
    done
fi

# Write a minimal isolinux.cfg if none exists
if [[ ! -f "${ISO_DIR}/isolinux/isolinux.cfg" ]]; then
    cat > "${ISO_DIR}/isolinux/isolinux.cfg" << 'ISOCFG'
DEFAULT enderarch
LABEL enderarch
    LINUX ../boot/x86_64/vmlinuz-linux
    INITRD ../boot/x86_64/initramfs-enderarch.img
    APPEND root=live:LABEL=ENDERARCH quiet splash
ISOCFG
    echo "    Wrote default isolinux.cfg"
fi

# -- Create an EFI boot partition image for UEFI hybrid boot --
# This FAT image is referenced by xorriso's -e flag for the UEFI boot chain.
if [[ -f "${ISO_DIR}/EFI/BOOT/BOOTx64.EFI" ]]; then
    echo "    Creating EFI boot partition image..."
    EFI_IMG="${ISO_DIR}/EFI/BOOT/efi.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=10 2>/dev/null
    mkfs.fat -F32 "$EFI_IMG" 2>/dev/null || {
        echo "    Warning: mkfs.fat not available; EFI boot image not created"
        rm -f "$EFI_IMG"
    }
    if [[ -f "$EFI_IMG" ]]; then
        # Mount, copy EFI directory, unmount
        MNT=$(mktemp -d)
        mount "$EFI_IMG" "$MNT"
        mkdir -p "$MNT/EFI/BOOT"
        cp "${ISO_DIR}/EFI/BOOT/BOOTx64.EFI" "$MNT/EFI/BOOT/"
        if [[ -f "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" ]]; then
            cp "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" "$MNT/EFI/BOOT/"
        fi
        umount "$MNT"
        rmdir "$MNT"
        echo "    EFI boot partition image created: ${EFI_IMG}"
    fi
fi

fi
# ==================================================================
# Phase 6: Generating ISO
# ==================================================================
echo "==> Phase 6: Generating ISO"
if [[ $START_PHASE -le 6 ]]; then

XORRISO_ARGS=(
    -as mkisofs
    -V "ENDERARCH_${FLAVOR}"
    -iso-level 3
    -full-iso9660-filenames
    -eltorito-boot isolinux/isolinux.bin
    -eltorito-catalog isolinux/boot.cat
    -no-emul-boot -boot-load-size 4 -boot-info-table
)

# MBR for hybrid BIOS/UEFI boot
if [[ -f "/usr/lib/syslinux/bios/isohdpfx.bin" ]]; then
    XORRISO_ARGS+=(-isohybrid-mbr /usr/lib/syslinux/bios/isohdpfx.bin)
fi

# x86_64 UEFI boot entry
if [[ -f "${ISO_DIR}/EFI/BOOT/efi.img" ]]; then
    XORRISO_ARGS+=(-eltorito-alt-boot -e EFI/BOOT/efi.img -no-emul-boot)
fi

# ARM64 UEFI boot entry (separate alt-boot if EFI image contains AA64)
if [[ -f "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" && ! -f "${ISO_DIR}/EFI/BOOT/efi.img" ]]; then
    XORRISO_ARGS+=(-eltorito-alt-boot -e EFI/BOOT/BOOTAA64.EFI -no-emul-boot)
fi

XORRISO_ARGS+=(-isohybrid-gpt-basdat)
XORRISO_ARGS+=(-o "${OUT_DIR}/${ISONAME_FULL}.iso")
XORRISO_ARGS+=("${ISO_DIR}")

echo "    Running xorriso..."
xorriso "${XORRISO_ARGS[@]}"

echo ""
echo "==> Done: ${OUT_DIR}/${ISONAME_FULL}.iso"

fi