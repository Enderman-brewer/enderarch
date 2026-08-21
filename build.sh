#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Cleanup trap ---
# Track temp mount points and loop devices so we can clean up on exit
_MNT_DIRS=()
cleanup() {
    local dir
    for dir in "${_MNT_DIRS[@]}"; do
        if mountpoint -q "$dir" 2>/dev/null; then
            echo "==> Cleanup: unmounting $dir"
            umount "$dir" 2>/dev/null || true
        fi
        [[ -d "$dir" ]] && rmdir "$dir" 2>/dev/null || true
    done
    # Detach any remaining loop devices backed by our ISO dir
    for loop in $(losetup -l -n -O NAME,BACK-FILE 2>/dev/null | grep "$SCRIPT_DIR/iso" | awk '{print $1}'); do
        losetup -d "$loop" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

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
            echo "  flavor:     vanilla | mingui | cgui"
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
         "${ISO_DIR}/LiveOS" \
         "${OUT_DIR}"

# ------------------------------------------------------------------
# Check required tools
# ------------------------------------------------------------------
REQUIRED_CMDS=(pacstrap arch-chroot mksquashfs mkinitcpio grub-mkimage)
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required tool '$cmd' not found. Please install it."
        exit 1
    fi
done
# ISO generator with UDF support (checked up front for fast feedback)
if ! command -v mkisofs &>/dev/null && ! command -v genisoimage &>/dev/null; then
    echo "Error: no ISO generator with UDF support found."
    echo "  Install 'cdrtools' (mkisofs, preferred) or 'cdrkit' (genisoimage)."
    exit 1
fi

# ==================================================================
# Phase 1: Installing base system (x86_64)
# ==================================================================
if [[ $START_PHASE -le 1 ]]; then
echo "==> Phase 1: Installing base system (x86_64)"

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
if [[ $START_PHASE -le 2 ]]; then
echo "==> Phase 1b: Copying overlay files"

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
    cgui)
        arch-chroot "$WORKDIR" systemctl enable lightdm.service 2>/dev/null || true
        echo "    LightDM enabled for CGUI"
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
if [[ $START_PHASE -le 2 ]]; then
echo "==> Phase 2: Creating squashfs"

rm -f "$ROOTFS_SFS"
echo "    Running mksquashfs (this may take a while)..."
mksquashfs "$WORKDIR" "$ROOTFS_SFS" -comp zstd -Xcompression-level 15

fi
# ==================================================================
# Phase 3: Building x86_64 initrds
# ==================================================================
if [[ $START_PHASE -le 3 ]]; then
echo "==> Phase 3: Building x86_64 initrds"

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
    cp "${SCRIPTS_DIR}/enderarch-fail" "${WORKDIR}/lib/enderarch/"
    # NOTE: qemu-x86_64-static is intentionally NOT staged into the x86_64
    # chroot. The emulator is only needed for ARM64 boots, and the
    # enderarch-common install hook adds it to the initrd from the ARM
    # chroot's qemu-user-static-bin package (aarch64 build).

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
if [[ $START_PHASE -le 4 ]]; then
echo "==> Phase 4: Building ARM64 initrds (if available)"

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

        # Register qemu-aarch64-static in the chroot BEFORE pacstrap so that
        # package post-install scriptlets can run chrooted under emulation.
        # (pacstrap -c only uses the host package cache; it does not wipe the
        # target directory.)
        mkdir -p "$ARM_WORKDIR/usr/bin"
        cp "$(command -v qemu-aarch64-static)" "$ARM_WORKDIR/usr/bin/"

        echo "    Installing ARM64 packages: ${ARM_PACKAGES[*]}"
        pacstrap -c -G -M "$ARM_WORKDIR" "${ARM_PACKAGES[@]}" < /dev/null

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
        cp "${SCRIPTS_DIR}/enderarch-fail" "${ARM_WORKDIR}/lib/enderarch/"
        # The aarch64-built qemu-x86_64-static is provided inside the ARM
        # chroot by the qemu-user-static-bin package. Do NOT copy the host's
        # x86_64 build here — it would clobber the aarch64 binary. The
        # enderarch-common install hook adds it to the ARM initrd.
        if [[ ! -f "${ARM_WORKDIR}/usr/bin/qemu-x86_64-static" ]]; then
            echo "    Warning: qemu-x86_64-static not found in ARM chroot; x86_64 emulation will be unavailable on ARM boot"
        fi

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
                        cp "${SCRIPTS_DIR}/88-enderloader.sh" "${ARM_WORKDIR}/etc/profile.d/" 2>/dev/null || true
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
if [[ $START_PHASE -le 5 ]]; then
echo "==> Phase 5: Staging ISO files"

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

# -- GRUB fonts (needed for gfxterm rendering) --
if [[ -d "/usr/share/grub" ]]; then
    mkdir -p "${ISO_DIR}/boot/grub/fonts"
    cp -a /usr/share/grub/*.pf2 "${ISO_DIR}/boot/grub/fonts/" 2>/dev/null || true
fi

# -- Standalone GRUB EFI boot executables --
# 'udf' is required to read the UDF bridge volume; iso9660 stays as a fallback
# for the carrier structures and older media.
GRUB_MODULES="part_msdos part_gpt fat udf iso9660 squash4 linux loopback search search_fs_file search_fs_uuid search_label normal configfile echo ls reboot halt efi_gop efi_uga"
for grub_target in x86_64-efi arm64-efi; do
    case "$grub_target" in
        x86_64-efi) efi_name=BOOTX64.EFI ;;
        arm64-efi) efi_name=BOOTAA64.EFI ;;
    esac
    echo "    Building ${efi_name} with grub-mkimage..."
    grub-mkimage -O "$grub_target" \
        -o "${ISO_DIR}/EFI/BOOT/${efi_name}" \
        -p /boot/grub \
        -c "${GRUB_DIR}/embed.cfg" \
        $GRUB_MODULES 2>/dev/null || {
        echo "    Warning: could not build ${efi_name}"
        rm -f "${ISO_DIR}/EFI/BOOT/${efi_name}"
    }
done

# -- GRUB i386-pc BIOS boot image --
if command -v grub-mkimage &>/dev/null; then
    echo "    Building GRUB i386-pc BIOS boot image via grub-mkimage -O i386-pc-eltorito..."
    GRUB_BIOS_CD="${ISO_DIR}/boot/grub/i386-pc/eltorito.img"
    # Use grub-mkimage -O i386-pc-eltorito which properly prepends cdboot.img
    # and patches the core.img offset/size at bytes 0x10/0x14 so cdboot.img can
    # find and load core.img. Without this patch, the BIOS hangs after loading
    # cdboot.img with junk (zeroed offsets).
    #
    # IMPORTANT: Use grub-mkimage (NOT grub-mkstandalone) which includes ONLY
    # the explicitly listed modules. grub-mkstandalone packs ALL modules into
    # the core image, which exceeds the 480KB size limit (0x78000) for the
    # i386-pc-eltorito format and fails silently.
    #
    # The -c embed.cfg early config searches for /boot/grub/grub.cfg on the ISO
    # and loads it. The -p flag sets GRUB's prefix path for module loading.
    grub-mkimage -O i386-pc-eltorito \
        -o "$GRUB_BIOS_CD" \
        -p /boot/grub \
        -c "${GRUB_DIR}/embed.cfg" \
        linux loopback udf iso9660 squash4 ext2 part_msdos part_gpt \
        search search_fs_file search_label normal configfile echo test true \
        biosdisk 2>/dev/null || {
        echo "    Warning: grub-mkimage failed for BIOS boot"
        rm -f "$GRUB_BIOS_CD"
    }
    if [[ -f "$GRUB_BIOS_CD" ]]; then
        echo "    Created GRUB i386-pc eltorito boot image"
    fi
fi

# -- Create an EFI boot partition image for UEFI hybrid boot --
# This FAT image becomes the second El Torito entry (platform id 0xEF) and,
# after isohybrid --uefi, the GPT/MBR ESP partition for USB boot.
if [[ -f "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" || -f "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" ]]; then
    echo "    Creating EFI boot partition image..."
    EFI_IMG="${ISO_DIR}/EFI/BOOT/efi.img"
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=32 2>/dev/null
    mkfs.fat -F32 "$EFI_IMG" 2>/dev/null || {
        echo "    Warning: mkfs.fat not available; EFI boot image not created"
        rm -f "$EFI_IMG"
    }
    if [[ -f "$EFI_IMG" ]]; then
        # Mount, copy EFI directory, unmount
        MNT=$(mktemp -d)
        _MNT_DIRS+=("$MNT")  # register with cleanup trap
        if mount "$EFI_IMG" "$MNT" 2>/dev/null; then
            mkdir -p "$MNT/EFI/BOOT"
            cp "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" "$MNT/EFI/BOOT/"
            if [[ -f "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" ]]; then
                cp "${ISO_DIR}/EFI/BOOT/BOOTAA64.EFI" "$MNT/EFI/BOOT/"
            fi
            umount "$MNT"
            rmdir "$MNT"
            echo "    EFI boot partition image created: ${EFI_IMG}"
        else
            echo "    Warning: could not mount EFI image; EFI boot partition image not created"
            umount "$MNT" 2>/dev/null || true
            rmdir "$MNT" 2>/dev/null || true
            rm -f "$EFI_IMG"
        fi
    fi
fi

fi
# ==================================================================
# Phase 6: Generating ISO
# ==================================================================
if [[ $START_PHASE -le 6 ]]; then
echo "==> Phase 6: Generating ISO"

ISO_OUT="${OUT_DIR}/${ISONAME_FULL}.iso"

# ------------------------------------------------------------------
# Locate an ISO generator with UDF support.
# xorriso cannot write UDF, so we use the classic mkisofs family:
#   mkisofs     (cdrtools) — "Rationalized UDF", preferred
#   genisoimage (cdrkit)   — alpha UDF, acceptable fallback
# ------------------------------------------------------------------
ISO_GEN=""
for cand in mkisofs genisoimage; do
    if command -v "$cand" &>/dev/null; then
        ISO_GEN="$cand"
        break
    fi
done
if [[ -z "$ISO_GEN" ]]; then
    echo "Error: no ISO generator found. Install 'cdrtools' (mkisofs)"
    echo "  or 'cdrkit' (genisoimage). xorriso cannot write UDF."
    exit 1
fi
echo "    Using ISO generator: ${ISO_GEN}"

# Filesystem layout: ISO 9660/UDF bridge (the same pattern Windows uses for
# its own ISOs). The full payload lives in the UDF filesystem; a minimal
# ISO 9660 carrier exists only to host the El Torito boot records. Modern
# OSes auto-mount the UDF view, which removes the CDFS limitations (4GB file
# ceiling, no POSIX metadata, path depth).
#   -r  Rock Ridge: permissions/symlinks for Linux
#   -J  Joliet (+-joliet-long): long filenames for Windows Explorer
#   -udf  the actual payload filesystem
GEN_ARGS=(
    -V "ENDERARCH_${FLAVOR}"
    -iso-level 3
    -r
    -J
    -joliet-long
    -udf
)

# BIOS boot: GRUB i386-pc El Torito image (paths are relative to ISO_DIR)
if [[ -f "${ISO_DIR}/boot/grub/i386-pc/eltorito.img" ]]; then
    echo "    El Torito BIOS entry: GRUB i386-pc eltorito.img"
    GEN_ARGS+=(
        -b boot/grub/i386-pc/eltorito.img
        -c boot/grub/boot.cat
        -no-emul-boot -boot-load-size 4 -boot-info-table
    )
else
    echo "    Warning: no BIOS eltorito.img staged; CD BIOS boot unavailable"
fi

# UEFI boot: FAT ESP image as second El Torito entry (platform id 0xEF).
# There is NO portable syntax: cdrtools uses -eltorito-platform, while -e
# only exists in RedHat's patched genisoimage (plain Debian cdrkit has no
# EFI support at all). Pick by binary name, retry the other on rejection.
EFI_PRIMARY=()
EFI_FALLBACK=()
if [[ -f "${ISO_DIR}/EFI/BOOT/efi.img" ]]; then
    echo "    El Torito UEFI entry: EFI/BOOT/efi.img"
    if [[ "$ISO_GEN" = "mkisofs" ]]; then
        EFI_PRIMARY=(-eltorito-alt-boot -eltorito-platform efi -b EFI/BOOT/efi.img -no-emul-boot)
        EFI_FALLBACK=(-eltorito-alt-boot -e EFI/BOOT/efi.img -no-emul-boot)
    else
        EFI_PRIMARY=(-eltorito-alt-boot -e EFI/BOOT/efi.img -no-emul-boot)
        EFI_FALLBACK=(-eltorito-alt-boot -eltorito-platform efi -b EFI/BOOT/efi.img -no-emul-boot)
    fi
else
    echo "    Warning: no EFI/BOOT/efi.img staged; CD UEFI boot unavailable"
fi

run_generator() {
    "$ISO_GEN" "${GEN_ARGS[@]}" "${EFI_PRIMARY[@]+"${EFI_PRIMARY[@]}"}" \
        -o "$ISO_OUT" "$ISO_DIR"
}

echo "    Generating ${ISO_OUT} ..."

# cdrkit's genisoimage has alpha-grade UDF with unreliable >4GB file support;
# warn loudly rather than shipping a silently broken payload.
if [[ "$ISO_GEN" = "genisoimage" ]]; then
    big=$(find "$ISO_DIR" -type f -size +4G -print -quit 2>/dev/null || true)
    if [[ -n "$big" ]]; then
        echo "    WARNING: ${big} exceeds 4GB and genisoimage's UDF is alpha."
        echo "    Install cdrtools (mkisofs) for reliable >4GB UDF support."
    fi
fi

GEN_RC=0
GEN_OUT="$(run_generator)" || GEN_RC=$?
[[ -n "$GEN_OUT" ]] && printf '%s\n' "$GEN_OUT"

if [[ $GEN_RC -ne 0 ]]; then
    if [[ ${#EFI_PRIMARY[@]} -gt 0 ]] && \
       printf '%s\n' "$GEN_OUT" | grep -qiE 'bad option|invalid option|unknown option|unsupported option'; then
        echo "    Generator rejected the El Torito EFI syntax; retrying with alternate..."
        run_generator_retry() {
            "$ISO_GEN" "${GEN_ARGS[@]}" "${EFI_FALLBACK[@]+"${EFI_FALLBACK[@]}"}" \
                -o "$ISO_OUT" "$ISO_DIR"
        }
        run_generator_retry || {
            echo "Error: ISO generation failed with both EFI entry syntaxes."
            echo "  Note: unpatched cdrkit 'genisoimage' cannot write EFI El Torito"
            echo "  entries at all — install cdrtools ('mkisofs') instead."
            exit 1
        }
    else
        exit $GEN_RC
    fi
fi

# ------------------------------------------------------------------
# Hybridize for USB sticks (dd the ISO to a block device and it boots).
# isohybrid stamps an MBR that re-enters the El Torito boot path when the
# medium appears as a hard disk; --uefi additionally adds a GPT entry for
# the EFI partition so UEFI firmware finds the ESP on USB.
#
# NOTE: isohybrid from syslinux checks for an isolinux.bin hybrid signature
# and will fail on GRUB eltorito images. The ISO still boots fine from
# CD/DVD (El Torito BIOS + UEFI). For USB stick creation, use
# `grub-install` on the target device separately; that is outside this
# build's scope.
# ------------------------------------------------------------------
if ! command -v isohybrid &>/dev/null; then
    echo "  Note: 'isohybrid' not found — skipping USB hybridization."
    echo "  The ISO boots from CD/DVD; for USB see README instructions."
else
    if isohybrid --help 2>&1 | grep -q -- '--uefi'; then
        echo "    Stamping hybrid MBR + GPT (isohybrid --uefi)..."
        isohybrid --uefi "$ISO_OUT" || \
            echo "    Warning: isohybrid --uefi failed; ISO remains CD/DVD-bootable."
    else
        echo "    Stamping hybrid MBR (isohybrid; no --uefi support)..."
        echo "    Warning: isohybrid does not support GRUB eltorito images; skipping."
    fi
fi

echo ""
echo "==> Done: ${ISO_OUT}"

fi