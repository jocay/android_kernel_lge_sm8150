#!/usr/bin/env bash
# ==============================================================================
# LG G8 (alphaplus, SM8150) LineageOS 23.2 (Android 16) kernel build script
# ==============================================================================
#
# Only the kernel inside the boot partition is replaced. The phone has no
# fastboot, so the main product is an AnyKernel3 zip for "adb sideload" in
# Lineage Recovery: it swaps the kernel in the boot image that is on the
# device and keeps its ramdisk (which is also the recovery), dtb and
# recovery_dtbo. A complete boot.img is built as well, for flashing by other
# means (EDL / dd).
#
# The device trees are not rebuilt: the dtb stays in the boot image and the
# dtbo partition is not touched. (The overlay sources need the external dtc of
# the Android build; the in-tree dtc cannot parse them.)
#
# Environment:
#   TOOLS            tool root (default ~/android/tools), laid out as
#                    toolchains/clang-r563880c, boot/mkbootimg, boot/avb,
#                    ota/payload-dumper-go, anykernel/AnyKernel3, downloads/.
#                    Missing tools are downloaded.
#   IMAGES_DIR       directory holding the LineageOS OTA zip (default ../images)
#   OTA_ZIP          the OTA zip that is installed on the phone (default: the
#                    only lineage-*-alphaplus.zip in IMAGES_DIR)
#   OFFICIAL_DIR     boot.img and vendor_modules/*.ko of that OTA (default
#                    IMAGES_DIR/<zip name without -UNOFFICIAL-alphaplus.zip>);
#                    extracted from OTA_ZIP when missing.
#   AK3_REF_ZIP      a known-good AnyKernel3 zip for this device, used as the
#                    packaging template when TOOLS/anykernel/AnyKernel3 is
#                    missing (default IMAGES_DIR/ALPHA-LOS-23.2-KSUN+SUSFS.zip)
#   EXTRA_CONFIGS    space-separated config fragments (paths, or names under
#                    arch/arm64/configs/vendor) merged over the official
#                    config. Default: the optional fragments present in the
#                    tree. Set it empty for a stock build.
#   KERNEL_NAME      name used for the zip and shown while flashing (default
#                    "stock" without fragments, "custom" with)
#   STRICT_ABI=1     fail when an exported symbol used by the official vendor
#                    modules changes (default: warn)
#   JOBS             parallel jobs (default: all cores).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="${TOOLS:-$HOME/android/tools}"
IMAGES_DIR="${IMAGES_DIR:-$ROOT_DIR/../images}"
JOBS="${JOBS:-$(nproc)}"

AOSP_TAG="android-16.0.0_r4"
AOSP_URL="https://android.googlesource.com/platform"
PAYLOAD_DUMPER_VERSION="2.1.0"
CLANG_DIR="$TOOLS/toolchains/clang-r563880c"
MKBOOTIMG_DIR="$TOOLS/boot/mkbootimg"
AVB_DIR="$TOOLS/boot/avb"
PAYLOAD_DUMPER_DIR="$TOOLS/ota/payload-dumper-go"
AK3_DIR="$TOOLS/anykernel/AnyKernel3"
AK3_REF_ZIP="${AK3_REF_ZIP:-$IMAGES_DIR/ALPHA-LOS-23.2-KSUN+SUSFS.zip}"

CONFIG_DIR="$ROOT_DIR/arch/arm64/configs/vendor"
OPTIONAL_CONFIGS="kernelsu_next.config droidspaces.config server_net.config"

OUT_DIR="$ROOT_DIR/out"
KERNEL_OBJ="$OUT_DIR/kernel_obj"
UNPACK_DIR="$OUT_DIR/official_boot_unpacked"
OFFICIAL_CONFIG="$OUT_DIR/official_kernel.config"
BOOT_IMG_OUT="$OUT_DIR/boot.img"

echo "=================================================================="
echo " Building kernel for LG G8 (alphaplus) - LineageOS 23.2"
echo "=================================================================="

for cmd in make bc bison flex python3 curl tar gzip zip unzip debugfs aarch64-linux-gnu-gcc; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is missing." >&2
        echo "Install dependencies: sudo apt install -y build-essential bc bison flex libssl-dev python3 libelf-dev gcc-aarch64-linux-gnu curl tar zip unzip e2fsprogs" >&2
        exit 1
    fi
done

# fetch_tool <archive name> <url> <destination> <file that proves it is complete>
# The archive is downloaded and unpacked next to its final location and only
# moved into place when complete, so an interrupted run leaves nothing behind
# that a later run would mistake for a finished install.
fetch_tool() {
    local name=$1 url=$2 dest=$3 marker=$4
    local archive="$TOOLS/downloads/$name.tar.gz"
    [[ -e "$dest/$marker" ]] && return 0
    echo "Fetching $name ..."
    mkdir -p "$TOOLS/downloads" "$(dirname "$dest")"
    if [[ ! -f "$archive" ]]; then
        curl -fL --retry 3 --connect-timeout 30 "$url" -o "$archive.part"
        mv "$archive.part" "$archive"
    fi
    rm -rf "$dest" "$dest.tmp"
    mkdir -p "$dest.tmp"
    tar -xzf "$archive" -C "$dest.tmp"
    mv "$dest.tmp" "$dest"
}

echo "=== [1/7] Checking tools in $TOOLS ==="
fetch_tool clang-r563880c \
    "$AOSP_URL/prebuilts/clang/host/linux-x86/+archive/refs/tags/$AOSP_TAG/clang-r563880c.tar.gz" \
    "$CLANG_DIR" bin/clang
fetch_tool "mkbootimg-$AOSP_TAG" \
    "$AOSP_URL/system/tools/mkbootimg/+archive/refs/tags/$AOSP_TAG.tar.gz" \
    "$MKBOOTIMG_DIR" mkbootimg.py
fetch_tool "avb-$AOSP_TAG" \
    "$AOSP_URL/external/avb/+archive/refs/tags/$AOSP_TAG.tar.gz" \
    "$AVB_DIR" avbtool.py
if [[ ! -f "$AK3_DIR/tools/ak3-core.sh" ]]; then
    # The template is taken from a zip that is known to flash on this device
    # rather than from upstream AnyKernel3, whose tools may behave differently.
    [[ -f "$AK3_REF_ZIP" ]] || { echo "Error: no AnyKernel3 template at $AK3_DIR and no $AK3_REF_ZIP to take one from" >&2; exit 1; }
    echo "Taking the AnyKernel3 template from ${AK3_REF_ZIP##*/} ..."
    rm -rf "$AK3_DIR" "$AK3_DIR.tmp"
    mkdir -p "$AK3_DIR.tmp"
    unzip -q "$AK3_REF_ZIP" -x Image -d "$AK3_DIR.tmp"
    mv "$AK3_DIR.tmp" "$AK3_DIR"
fi

export PATH="$CLANG_DIR/bin:$PATH"
echo "Using compiler: $(clang --version | head -n 1)"

# LD is passed explicitly although LLVM=1 selects ld.lld as well: this tree
# decides "is the linker lld" before LLVM=1 takes effect, and only an explicit
# LD makes it add the lld-specific flags (-O2 string merging) that the official
# kernel was linked with.
MAKE_ARGS=(
    -C "$ROOT_DIR" O="$KERNEL_OBJ" ARCH=arm64 SUBARCH=arm64
    LLVM=1 LLVM_IAS=1 LD=ld.lld
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-gnu-
)

echo "=== [2/7] Locating the official images ==="
if [[ -z "${OFFICIAL_DIR:-}" ]]; then
    if [[ -z "${OTA_ZIP:-}" ]]; then
        shopt -s nullglob
        zips=("$IMAGES_DIR"/lineage-*-alphaplus.zip)
        shopt -u nullglob
        [[ ${#zips[@]} -eq 1 ]] || {
            echo "Error: expected exactly one lineage-*-alphaplus.zip in $IMAGES_DIR, found ${#zips[@]}." >&2
            echo "Set OTA_ZIP to the build that is installed on the phone." >&2
            exit 1; }
        OTA_ZIP="${zips[0]}"
    fi
    OFFICIAL_DIR="$IMAGES_DIR/$(basename "$OTA_ZIP" -UNOFFICIAL-alphaplus.zip)"
fi
OFFICIAL_BOOT="$OFFICIAL_DIR/boot.img"
OFFICIAL_MODULES="$OFFICIAL_DIR/vendor_modules"
if [[ ! -f "$OFFICIAL_BOOT" || ! -d "$OFFICIAL_MODULES" ]]; then
    [[ -f "${OTA_ZIP:-}" ]] || { echo "Error: $OFFICIAL_DIR is incomplete and there is no OTA zip to extract it from" >&2; exit 1; }
    echo "Extracting boot, dtbo, vbmeta and the vendor modules from ${OTA_ZIP##*/} ..."
    fetch_tool "payload-dumper-go_${PAYLOAD_DUMPER_VERSION}_linux_amd64" \
        "https://github.com/ssut/payload-dumper-go/releases/download/$PAYLOAD_DUMPER_VERSION/payload-dumper-go_${PAYLOAD_DUMPER_VERSION}_linux_amd64.tar.gz" \
        "$PAYLOAD_DUMPER_DIR" payload-dumper-go
    mkdir -p "$OUT_DIR"
    tmp="$(mktemp -d "$OUT_DIR/ota.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    unzip -q "$OTA_ZIP" payload.bin -d "$tmp"
    "$PAYLOAD_DUMPER_DIR/payload-dumper-go" -p boot,dtbo,vbmeta,vendor -o "$tmp/out" "$tmp/payload.bin" > /dev/null
    mkdir -p "$tmp/vendor_modules"
    debugfs -R "rdump /lib/modules $tmp/vendor_modules" "$tmp/out/vendor.img" 2> /dev/null
    mkdir -p "$OFFICIAL_DIR"
    mv "$tmp/out/boot.img" "$tmp/out/dtbo.img" "$tmp/out/vbmeta.img" "$OFFICIAL_DIR/"
    rm -rf "$OFFICIAL_MODULES"
    mkdir "$OFFICIAL_MODULES"
    mv "$tmp"/vendor_modules/modules/*.ko "$OFFICIAL_MODULES/"
    rm -rf "$tmp"
    trap - EXIT
fi
echo "Official images: $OFFICIAL_DIR"

# Everything taken from the official image is re-read on every run, so a
# replaced boot.img can never be mixed with stale leftovers.
echo "=== [3/7] Reading the official boot image ==="
mkdir -p "$OUT_DIR"
rm -rf "$UNPACK_DIR"
MKBOOTIMG_ARGS=()
while IFS= read -r -d '' arg; do
    MKBOOTIMG_ARGS+=("$arg")
done < <(python3 "$MKBOOTIMG_DIR/unpack_bootimg.py" --boot_img "$OFFICIAL_BOOT" --out "$UNPACK_DIR" --format=mkbootimg -0)
python3 "$MKBOOTIMG_DIR/unpack_bootimg.py" --boot_img "$OFFICIAL_BOOT" --out "$UNPACK_DIR" > "$OUT_DIR/official_boot_info.txt"
AVB_INFO="$(python3 "$AVB_DIR/avbtool.py" info_image --image "$OFFICIAL_BOOT")"
PARTITION_SIZE="$(stat -c%s "$OFFICIAL_BOOT")"
SALT="$(sed -n 's/^ *Salt: *//p' <<<"$AVB_INFO")"
AVB_OS_VERSION="$(sed -n "s/^ *Prop: com.android.build.boot.os_version -> '\(.*\)'$/\1/p" <<<"$AVB_INFO")"
FINGERPRINT="$(sed -n "s/^ *Prop: com.android.build.boot.fingerprint -> '\(.*\)'$/\1/p" <<<"$AVB_INFO")"
# The official kernel is gzip-compressed inside the boot image.
OFFICIAL_IMAGE="$OUT_DIR/official_Image"
gzip -dc "$UNPACK_DIR/kernel" > "$OFFICIAL_IMAGE"
OFFICIAL_RELEASE="$(grep -a -m1 -o 'Linux version [0-9][^ ]*' "$OFFICIAL_IMAGE" | awk '{print $3}')"
echo "Official kernel: $OFFICIAL_RELEASE, boot header v$(sed -n 's/^boot image header version: //p' "$OUT_DIR/official_boot_info.txt")," \
     "OS $(sed -n 's/^os version: //p' "$OUT_DIR/official_boot_info.txt")," \
     "patch level $(sed -n 's/^os patch level: //p' "$OUT_DIR/official_boot_info.txt")"

echo "=== [4/7] Preparing Kernel Configuration ==="
# Regenerated on every run so config edits are never silently ignored.
# Base: the config embedded in the official kernel (CONFIG_IKCONFIG).
mkdir -p "$KERNEL_OBJ"
# CONFIG_LOCALVERSION_AUTO is off, so the official release only carries the
# "+" that setlocalversion adds for a tree that is not on a tag. Any content
# here produces that "+", whatever state this checkout is in.
echo "+" > "$ROOT_DIR/.scmversion"
"$ROOT_DIR/scripts/extract-ikconfig" "$OFFICIAL_IMAGE" > "$OFFICIAL_CONFIG.tmp"
mv "$OFFICIAL_CONFIG.tmp" "$OFFICIAL_CONFIG"
if [[ -z "${EXTRA_CONFIGS+set}" ]]; then
    EXTRA_CONFIGS=""
    for f in $OPTIONAL_CONFIGS; do
        [[ -f "$CONFIG_DIR/$f" ]] && EXTRA_CONFIGS+=" $f"
    done
fi
EXTRA=()
for f in $EXTRA_CONFIGS; do
    [[ -f "$f" ]] || f="$CONFIG_DIR/$f"
    [[ -f "$f" ]] || { echo "Error: config fragment $f not found" >&2; exit 1; }
    EXTRA+=("$f")
done
if [[ ${#EXTRA[@]} -eq 0 ]]; then KERNEL_NAME="${KERNEL_NAME:-stock}"; else KERNEL_NAME="${KERNEL_NAME:-custom}"; fi
echo "Base: ${OFFICIAL_CONFIG##*/}  Extra: ${EXTRA[*]##*/}"
ARCH=arm64 "$ROOT_DIR/scripts/kconfig/merge_config.sh" -m -O "$KERNEL_OBJ" \
    "$OFFICIAL_CONFIG" "${EXTRA[@]}" > /dev/null
make "${MAKE_ARGS[@]}" olddefconfig
for f in "${EXTRA[@]}"; do
    while read -r opt; do
        grep -qxF "$opt" "$KERNEL_OBJ/.config" || {
            echo "Error: $opt from ${f##*/} did not survive olddefconfig" >&2; exit 1; }
    done < <(grep -E '^CONFIG_' "$f")
done
# What ends up different from the official config, for the record.
diff <(grep -E '^(# )?CONFIG_' "$OFFICIAL_CONFIG" | sort) \
     <(grep -E '^(# )?CONFIG_' "$KERNEL_OBJ/.config" | sort) > "$OUT_DIR/config_vs_official.diff" || true
echo "Config lines differing from the official kernel: $(grep -c '^[<>]' "$OUT_DIR/config_vs_official.diff" || true)" \
     "(see ${OUT_DIR##*/}/config_vs_official.diff)"

echo "=== [5/7] Compiling Kernel Image with $JOBS jobs ==="
make -j"$JOBS" "${MAKE_ARGS[@]}" Image.gz

KERNEL_IMAGE="$KERNEL_OBJ/arch/arm64/boot/Image"
RELEASE="$(cat "$KERNEL_OBJ/include/config/kernel.release")"
echo "Kernel release: $RELEASE ($(stat -c%s "$KERNEL_IMAGE") bytes, official $(stat -c%s "$OFFICIAL_IMAGE"))"
if [[ "$RELEASE" != "$OFFICIAL_RELEASE" ]]; then
    echo "Error: kernel release '$RELEASE' differs from the official '$OFFICIAL_RELEASE'." >&2
    exit 1
fi

# The vendor partition ships a few modules built with the official kernel.
# They are signed with that build's throw-away key and the config enforces
# signatures (CONFIG_MODULE_SIG_FORCE), so a rebuilt kernel does not load them
# whatever the ABI looks like. Their symbol CRCs are still compared: a
# mismatch on a stock build means the source or compiler is not the official
# one, and on other builds it shows which exported interfaces a change moved.
echo "=== [6/7] Checking exported symbols against the official vendor modules ==="
llvm-nm "$KERNEL_OBJ/vmlinux" | awk '$3 ~ /^__crc_/ {print substr($3, 7), $1}' | sort > "$OUT_DIR/current_crcs.txt"
python3 - "$OUT_DIR/current_crcs.txt" "$OFFICIAL_MODULES" "${STRICT_ABI:-}" <<'EOF'
import pathlib, struct, subprocess, sys, tempfile

crcs = {}
for line in open(sys.argv[1]):
    name, crc = line.split()
    crcs[name] = int(crc, 16)

modules = sorted(pathlib.Path(sys.argv[2]).glob("*.ko"))
if not modules:
    sys.exit("Error: no official vendor modules found")
checked = bad = 0
with tempfile.NamedTemporaryFile() as tmp:
    for mod in modules:
        subprocess.run(["llvm-objcopy", "-O", "binary", "--only-section=__versions",
                        str(mod), tmp.name], check=True)
        data = pathlib.Path(tmp.name).read_bytes()
        # struct modversion_info { unsigned long crc; char name[56]; }
        for off in range(0, len(data), 64):
            crc = struct.unpack_from("<Q", data, off)[0]
            name = data[off + 8:off + 64].split(b"\0")[0].decode()
            if name not in crcs:
                continue  # exported by another module, not by vmlinux
            checked += 1
            if crcs[name] != crc:
                bad += 1
                if bad <= 10:
                    print(f"  {mod.name}: {name} wants {crc:#x}, kernel has {crcs[name]:#x}",
                          file=sys.stderr)
if bad:
    msg = (f"{bad} of {checked} symbol CRCs differ from what the {len(modules)} official "
           "vendor modules were built against")
    if sys.argv[3]:
        sys.exit("Error: " + msg)
    print("Warning: " + msg, file=sys.stderr)
else:
    print(f"{checked} symbol CRCs used by {len(modules)} official vendor modules all match")
EOF

echo "=== [7/7] Packaging ==="
# Complete boot image: the official one with only the kernel replaced. All
# header fields (version, offsets, cmdline, dtb) come from the official image.
args=()
for ((i = 0; i < ${#MKBOOTIMG_ARGS[@]}; i++)); do
    if [[ "${MKBOOTIMG_ARGS[i]}" == --kernel ]]; then
        args+=(--kernel "$KERNEL_OBJ/arch/arm64/boot/Image.gz")
        i=$((i + 1))
    else
        args+=("${MKBOOTIMG_ARGS[i]}")
    fi
done
python3 "$MKBOOTIMG_DIR/mkbootimg.py" "${args[@]}" -o "$BOOT_IMG_OUT"
python3 "$AVB_DIR/avbtool.py" add_hash_footer \
    --image "$BOOT_IMG_OUT" \
    --partition_size "$PARTITION_SIZE" \
    --partition_name boot \
    --algorithm NONE \
    --salt "$SALT" \
    --prop "com.android.build.boot.os_version:$AVB_OS_VERSION" \
    --prop "com.android.build.boot.fingerprint:$FINGERPRINT"

# pack_zip <uncompressed Image> <zip> <description shown while flashing>
# The device check makes the zip refuse to flash anything but an alphaplus.
pack_zip() {
    local image=$1 zip=$2 string=$3 stage="$OUT_DIR/ak3_stage"
    rm -rf "$stage" "$zip"
    cp -r "$AK3_DIR" "$stage"
    cp "$image" "$stage/Image"
    sed -i -e "s|^kernel.string=.*|kernel.string=$string|" \
           -e "s|^device.name1=.*|device.name1=alphaplus|" \
           -e "/^do.modules=/i do.devicecheck=1" "$stage/anykernel.sh"
    (cd "$stage" && zip -q -r -9 "$zip" .)
    rm -rf "$stage"
    unzip -tq "$zip" > /dev/null
}
ZIP_OUT="$OUT_DIR/G8-alphaplus-$KERNEL_NAME.zip"
ROLLBACK_ZIP="$OUT_DIR/G8-alphaplus-official-kernel.zip"
BUILD_DATE="$(grep -a -m1 -o 'Linux version .*' "$KERNEL_IMAGE" | sed 's/.*SMP PREEMPT //')"
pack_zip "$KERNEL_IMAGE" "$ZIP_OUT" "LG G8 alphaplus $RELEASE [$KERNEL_NAME] built $BUILD_DATE"
pack_zip "$OFFICIAL_IMAGE" "$ROLLBACK_ZIP" "LG G8 alphaplus $OFFICIAL_RELEASE [official kernel of $(basename "$OFFICIAL_DIR")]"

echo "=================================================================="
echo " SUCCESS!"
echo " Sideload zip : $ZIP_OUT"
echo " Rollback zip : $ROLLBACK_ZIP (the official kernel, same packaging)"
echo " Full image   : $BOOT_IMG_OUT ($(stat -c%s "$BOOT_IMG_OUT") bytes)"
echo " To flash: boot Lineage Recovery, Apply update -> Apply from ADB, then"
echo "   adb sideload $ZIP_OUT"
echo "=================================================================="
