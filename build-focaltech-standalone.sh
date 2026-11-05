#!/bin/bash
set -euo pipefail

PKG_NAME="focaltech-ft9201-standalone"
PKG_VERSION="2.0.0"
ARCH="amd64"
OUTPUT_DEB="${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"

# Determine initial defaults from git config or environment variables
DEFAULT_MAINTAINER_NAME="${MAINTAINER_NAME:-$(git config user.name 2>/dev/null || echo "Bartlomiej Muryn")}"
DEFAULT_MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-$(git config user.email 2>/dev/null || echo "bmuryn@gmail.com")}"

# Prompt for maintainer details if running in an interactive terminal
if [ -t 0 ]; then
    echo "=================================================================="
    echo " Package Maintainer Configuration"
    echo "=================================================================="
    read -r -p "Maintainer Name [$DEFAULT_MAINTAINER_NAME]: " INPUT_NAME
    MAINTAINER_NAME="${INPUT_NAME:-$DEFAULT_MAINTAINER_NAME}"

    read -r -p "Maintainer Email [$DEFAULT_MAINTAINER_EMAIL]: " INPUT_EMAIL
    MAINTAINER_EMAIL="${INPUT_EMAIL:-$DEFAULT_MAINTAINER_EMAIL}"
    echo "------------------------------------------------------------------"
else
    MAINTAINER_NAME="$DEFAULT_MAINTAINER_NAME"
    MAINTAINER_EMAIL="$DEFAULT_MAINTAINER_EMAIL"
fi

MAINTAINER="${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>"
echo "Building package with Maintainer: $MAINTAINER"

BUILD_ROOT="/tmp/ft9201-standalone-build"
CACHE_DIR="$(pwd)/sources_cache"

# Verify host system build prerequisites
for cmd in patchelf python3 wget dpkg-deb find; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required build tool '$cmd' is missing. Install with: sudo apt install $cmd"
        exit 1
    fi
done

mkdir -p "$CACHE_DIR"

# Upstream package URLs
URL_FOCALTECH="https://github.com/ryenyuku/libfprint-ft9201/releases/download/1.94.4_20250219/libfprint-2-2_1.94.4%2Btod1-0ubuntu1.22.04.2_amd64_20250219.deb"
URL_LIBGUSB="http://archive.ubuntu.com/ubuntu/pool/main/libg/libgusb/libgusb2_0.3.4-0.1_amd64.deb"
URL_FPRINTD="http://archive.ubuntu.com/ubuntu/pool/main/f/fprintd/fprintd_1.94.2-1_amd64.deb"

echo "==> [1/7] Checking and downloading source packages into cache..."

download_if_missing() {
    local target="$1"
    local url="$2"
    if [ ! -f "$target" ]; then
        echo "    Downloading $(basename "$target")..."
        if ! wget -q --show-progress -O "$target" "$url"; then
            echo "ERROR: Failed to download $url"
            rm -f "$target"
            exit 1
        fi
    else
        echo "    Using local cached file: $(basename "$target")"
    fi
}

download_if_missing "$CACHE_DIR/focaltech.deb" "$URL_FOCALTECH"
download_if_missing "$CACHE_DIR/libgusb2.deb" "$URL_LIBGUSB"
download_if_missing "$CACHE_DIR/fprintd.deb" "$URL_FPRINTD"

echo "==> [2/7] Creating clean package staging tree..."
rm -rf "$BUILD_ROOT"
# Exclude D-Bus system directories to prevent dpkg overwrite conflicts with distribution fprintd
mkdir -p "$BUILD_ROOT"/{DEBIAN,opt/focaltech/{bin,libexec,lib},etc/systemd/system,etc/udev/rules.d}

WORK_EXT="/tmp/ft9201-extract"
rm -rf "$WORK_EXT"
mkdir -p "$WORK_EXT"/{ft,gusb,fprintd}

dpkg-deb -x "$CACHE_DIR/focaltech.deb" "$WORK_EXT/ft"
dpkg-deb -x "$CACHE_DIR/libgusb2.deb" "$WORK_EXT/gusb"
dpkg-deb -x "$CACHE_DIR/fprintd.deb" "$WORK_EXT/fprintd"

echo "==> [3/7] Copying binaries and libraries to /opt/focaltech..."
# Upstream proprietary and shim libraries
FPRINT_SO=$(find "$WORK_EXT/ft" -name "libfprint-2.so.2*" -type f | head -n 1)
GUSB_SO=$(find "$WORK_EXT/gusb" -name "libgusb.so.2*" -type f | head -n 1)
cp "$FPRINT_SO" "$BUILD_ROOT/opt/focaltech/lib/libfprint-2.so.2.0.0"
cp "$GUSB_SO" "$BUILD_ROOT/opt/focaltech/lib/libgusb-focal.so.2"
ln -sf libfprint-2.so.2.0.0 "$BUILD_ROOT/opt/focaltech/lib/libfprint-2.so.2"

# Dedicated fprintd daemon
FPRINTD_BIN=$(find "$WORK_EXT/fprintd" -name "fprintd" -type f -perm -0100 | head -n 1)
cp "$FPRINTD_BIN" "$BUILD_ROOT/opt/focaltech/libexec/fprintd"

# Standalone CLI tools (enroll, verify, list, delete)
for cli_tool in fprintd-enroll fprintd-verify fprintd-list fprintd-delete; do
    TOOL_PATH=$(find "$WORK_EXT/fprintd" -name "$cli_tool" -type f | head -n 1)
    if [ -f "$TOOL_PATH" ]; then
        cp "$TOOL_PATH" "$BUILD_ROOT/opt/focaltech/bin/"
    fi
done

echo "==> [4/7] Applying binary patch to FpIdEntry (2808:9338 -> 2808:93a9)..."
python3 - << 'EOF'
file_path = "/tmp/ft9201-standalone-build/opt/focaltech/lib/libfprint-2.so.2.0.0"
with open(file_path, "rb") as f:
    data = bytearray(f.read())

old_pattern = bytes.fromhex("3893000008280000") # pid 0x9338, vid 0x2808
new_pattern = bytes.fromhex("a993000008280000") # pid 0x93a9, vid 0x2808

count = data.count(old_pattern)
assert count == 1, f"Expected 1 instance of 2808:9338, found: {count}!"

data[:] = data.replace(old_pattern, new_pattern)
with open(file_path, "wb") as f:
    f.write(data)
print("    Binary USB ID patch applied successfully.")
EOF

echo "==> [5/7] Patching ELF headers (RPATH and library replacement)..."
# 1. libfprint -> link against isolated libgusb-focal and look in /opt/focaltech/lib
patchelf --replace-needed libgusb.so.2 libgusb-focal.so.2 "$BUILD_ROOT/opt/focaltech/lib/libfprint-2.so.2.0.0"
patchelf --set-rpath /opt/focaltech/lib "$BUILD_ROOT/opt/focaltech/lib/libfprint-2.so.2.0.0"

# 2. fprintd daemon -> resolve libfprint from /opt/focaltech/lib
patchelf --set-rpath /opt/focaltech/lib "$BUILD_ROOT/opt/focaltech/libexec/fprintd"

# 3. CLI tools -> set rpath
for bin in "$BUILD_ROOT/opt/focaltech/bin"/*; do
    [ -f "$bin" ] && patchelf --set-rpath /opt/focaltech/lib "$bin" || true
done

chmod 0755 "$BUILD_ROOT/opt/focaltech/lib"/*
chmod 0755 "$BUILD_ROOT/opt/focaltech/libexec"/*
chmod 0755 "$BUILD_ROOT/opt/focaltech/bin"/*

echo "==> [6/7] Generating configuration files and systemd unit..."

# Systemd override unit
cat << 'EOF' > "$BUILD_ROOT/etc/systemd/system/fprintd.service"
[Unit]
Description=Fingerprint Authentication Daemon (Isolated FocalTech FT9201)
Documentation=man:fprintd(1)
BusName=net.reactivated.Fprint

[Service]
Type=dbus
BusName=net.reactivated.Fprint
ExecStart=/opt/focaltech/libexec/fprintd
Environment="LD_LIBRARY_PATH=/opt/focaltech/lib"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# udev rules for the FT9201 sensor
cat << 'EOF' > "$BUILD_ROOT/etc/udev/rules.d/70-focaltech-ft9201.rules"
ACTION=="add|change", SUBSYSTEM=="usb", ATTRS{idVendor}=="2808", ATTRS{idProduct}=="93a9", ATTRS{dev}||ATTR{dev}, MODE="0660", GROUP="plugdev", TAG+="uaccess"
EOF

# Debian control file
cat << EOF > "$BUILD_ROOT/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: utils
Priority: optional
Architecture: ${ARCH}
Depends: libpam-fprintd, libc6, libglib2.0-0, libpolkit-gobject-1-0, libdbus-1-3
Maintainer: ${MAINTAINER}
Description: Fully standalone & isolated FocalTech FT9201 fingerprint stack.
 Bundles patched libfprint-tod1, focal libgusb shim, fprintd daemon and CLI tools
 completely inside /opt/focaltech. Immune to system libfprint updates.
EOF

# postinst script
cat << 'EOF' > "$BUILD_ROOT/DEBIAN/postinst"
#!/bin/sh
set -e

# Provide symlinks for CLI tools
for tool in fprintd-enroll fprintd-verify fprintd-list fprintd-delete; do
    if [ -f "/opt/focaltech/bin/$tool" ]; then
        ln -sf "/opt/focaltech/bin/$tool" "/usr/local/bin/$tool"
    fi
done

# Reload udev rules and trigger device subsystem
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --action=add --attr-match=idVendor=2808 --attr-match=idProduct=93a9 2>/dev/null || true
fi

# Reload systemd and restart only fprintd (avoid restarting D-Bus to prevent session crashes)
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload || true
    systemctl restart fprintd.service 2>/dev/null || true
fi

# Configure PAM with max-tries and timeout thresholds
PAM_FILE="/etc/pam.d/common-auth"
if [ -f "$PAM_FILE" ]; then
    cp "$PAM_FILE" "${PAM_FILE}.bak-ft-standalone"
    sed -i '/# FocalTech-FT9201-Start/,/# FocalTech-FT9201-End/d' "$PAM_FILE"
    sed -i '/pam_fprintd\.so/d' "$PAM_FILE"
    sed -i '/pam_u2f\.so/d' "$PAM_FILE"

    python3 - << 'PY'
pam_path = "/etc/pam.d/common-auth"
with open(pam_path, "r") as f:
    lines = f.readlines()

pam_block = [
    "# FocalTech-FT9201-Start\n",
    "auth\t[success=done default=ignore]\tpam_fprintd.so max-tries=3 timeout=10\n",
    "auth\t[success=done default=ignore]\tpam_u2f.so cue originator\n",
    "# FocalTech-FT9201-End\n"
]

inserted = False
new_lines = []
for line in lines:
    if not inserted and line.strip().startswith("auth"):
        new_lines.extend(pam_block)
        inserted = True
    new_lines.append(line)

if not inserted:
    new_lines = pam_block + lines

with open(pam_path, "w") as f:
    f.writelines(new_lines)
PY
fi

exit 0
EOF
chmod 0755 "$BUILD_ROOT/DEBIAN/postinst"

# prerm script
cat << 'EOF' > "$BUILD_ROOT/DEBIAN/prerm"
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
    systemctl stop fprintd.service 2>/dev/null || true
fi
for tool in fprintd-enroll fprintd-verify fprintd-list fprintd-delete; do
    rm -f "/usr/local/bin/$tool" 2>/dev/null || true
done
exit 0
EOF
chmod 0755 "$BUILD_ROOT/DEBIAN/prerm"

# postrm script
cat << 'EOF' > "$BUILD_ROOT/DEBIAN/postrm"
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    rm -rf /opt/focaltech
    PAM_FILE="/etc/pam.d/common-auth"
    if [ -f "$PAM_FILE" ]; then
        sed -i '/# FocalTech-FT9201-Start/,/# FocalTech-FT9201-End/d' "$PAM_FILE"
    fi
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload || true
    fi
fi
exit 0
EOF
chmod 0755 "$BUILD_ROOT/DEBIAN/postrm"

echo "==> [7/7] Building debian package: $OUTPUT_DEB..."
dpkg-deb --build --root-owner-group "$BUILD_ROOT" "$OUTPUT_DEB"

# Clean up temporary directories (cache persists for offline builds)
rm -rf "$BUILD_ROOT" "$WORK_EXT"

echo "------------------------------------------------------------------"
echo "Build completed successfully!"
echo "Generated package: $(pwd)/$OUTPUT_DEB"
echo "Cached archives:   $(pwd)/sources_cache/ (keep this for offline builds)"
echo "Install via:       sudo apt install ./$OUTPUT_DEB"
echo "------------------------------------------------------------------"