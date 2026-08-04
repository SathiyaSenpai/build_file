#!/bin/bash

set -e

TG_BOT_TOKEN="8640370988:AAEiYvxOVSNXNLyWzqTxzYD_IW5qUhRvyY8"
TG_CHAT_ID="-1003917803238"
DEVICE="avalon"

START_TIME=$(date +%s)
LOG_TAG="Voltage | avalon"

BUILD_CMD="brunch ${DEVICE}"

tg_send() {
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" > /dev/null 2>&1 || true
}

elapsed() {
    local ELAPSED=$(( $(date +%s) - START_TIME ))
    printf '%dh %dm %ds' $(( ELAPSED/3600 )) $(( (ELAPSED%3600)/60 )) $(( ELAPSED%60 ))
}

gofile_upload() {
    local FILE_PATH="$1"
    local FILENAME=$(basename "$FILE_PATH")
    echo "[*] Fetching best GoFile server..." >&2
    local SERVER=$(curl -s "https://api.gofile.io/servers" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['servers'][0]['name'], end='')" 2>/dev/null || true)
    if [ -z "$SERVER" ]; then
        echo "[!] Falling back to store1" >&2
        SERVER="store1"
    fi
    echo "[*] Uploading $FILENAME to $SERVER..." >&2
    local UPLOAD_RESPONSE=$(curl -s \
        -F "file=@${FILE_PATH}" \
        "https://${SERVER}.gofile.io/contents/uploadfile")
    echo "[*] GoFile response: $UPLOAD_RESPONSE" >&2
    echo "$UPLOAD_RESPONSE" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['downloadPage'], end='')" 2>/dev/null
}

tg_send "🔨 <b>${LOG_TAG}</b>
<b>Status:</b> Build started
<b>Device:</b> <code>${DEVICE}</code>
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S UTC')"

echo "════════════════════════════════════"
echo "  Voltage OS Build — OnePlus Nord 4"
echo "════════════════════════════════════"

#rm -rf vendor/voltage-priv/
rm -rf .repo/local_manifests/

echo "[*] Setting up local manifests..."
mkdir -p .repo/local_manifests

cat > .repo/local_manifests/voltage_avalon.xml << 'LOCALMANIFEST'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="sathiya"
          fetch="https://github.com/SathiyaSenpai" />
  <remote name="avalon-stuffs"
          fetch="https://github.com/avalon-stuffs" />
  <remote name="source"
          fetch="https://github.com/SenpaiSource" />
  <remote name="lineage"
          fetch="https://github.com/LineageOS" />
  <remote name="muppets"
          fetch="https://github.com/TheMuppets" />
  <remote name="yaap"
          fetch="https://github.com/yaap" />
          
  <project name="android_device_oneplus_avalon"
           path="device/oneplus/avalon"
           remote="sathiya"
           revision="voltage-bkp" />
  <project name="android_device_oneplus_sm8650-common"
           path="device/oneplus/sm8650-common"
           remote="lineage"
           revision="lineage-23.2" />
  <project name="android_kernel_oneplus_sm8650"
           path="kernel/oneplus/sm8650"
           remote="source"
           revision="lineage-23.2" />
  <project name="android_kernel_oneplus_sm8650-modules"
           path="kernel/oneplus/sm8650-modules"
           remote="source"
           revision="lineage-23.2" />
  <project name="android_kernel_oneplus_sm8650-devicetrees"
           path="kernel/oneplus/sm8650-devicetrees"
           remote="source"
           revision="lineage-23.2" />
  <project name="proprietary_vendor_oneplus_avalon"
           path="vendor/oneplus/avalon"
           remote="muppets"
           revision="lineage-23.2" />
  <project name="proprietary_vendor_oneplus_sm8650-common"
           path="vendor/oneplus/sm8650-common"
           remote="muppets"
           revision="lineage-23.2" />
  <project name="android_hardware_oplus"
           path="hardware/oplus"
           remote="sathiya"
           revision="voltage-bkp" />
  <project name="lineage-priv"
           path="vendor/voltage-priv"
           remote="sathiya"
           revision="voltage" />

</manifest>
LOCALMANIFEST

repo init -u https://github.com/VoltageOS/manifest.git -b 16.2 --git-lfs --depth=1

echo "[*] Syncing sources..."
tg_send "🔄 <b>${LOG_TAG}</b>
<b>Status:</b> Syncing sources..."

/opt/crave/resync.sh 2>&1

echo "[*] Sync complete."
tg_send "✅ <b>${LOG_TAG}</b>
<b>Status:</b> Sync done, starting compilation..."

set +e
echo "[*] Setting up build environment..."
. build/envsetup.sh

echo "[*] Brunching device: ${DEVICE} (userdebug)"

${BUILD_CMD} 2>&1
BUILD_STATUS=$?
set -e

if [ $BUILD_STATUS -eq 0 ]; then
    OUT_DIR="out/target/product/${DEVICE}"

    ZIP_FILE=$(find "${OUT_DIR}" -maxdepth 1 \( -name "Voltage-*.zip" -o -name "*${DEVICE}*.zip" \) \
               2>/dev/null | grep -v "ota_update" | head -1)

    BOOT_IMG="${OUT_DIR}/boot.img"
    RECOVERY_IMG="${OUT_DIR}/recovery.img"
    VENDOR_BOOT_IMG="${OUT_DIR}/vendor_boot.img"
    INIT_BOOT_IMG="${OUT_DIR}/init_boot.img"
    SUPER_EMPTY_IMG="${OUT_DIR}/super_empty.img"

    if [ -z "$ZIP_FILE" ]; then
        tg_send "⚠️ <b>${LOG_TAG}</b>
Build succeeded but ZIP not found in <code>${OUT_DIR}</code>
Elapsed: $(elapsed)"
        exit 1
    fi

    ZIP_SIZE=$(du -sh "$ZIP_FILE" | cut -f1)

    tg_send "📦 <b>${LOG_TAG}</b>
<b>Status:</b> Uploading to GoFile...
<b>File:</b> <code>$(basename $ZIP_FILE)</code>
<b>Size:</b> ${ZIP_SIZE}
<b>Elapsed:</b> $(elapsed)"

    DOWNLOAD_URL=$(gofile_upload "$ZIP_FILE")

    IMG_LINKS=""
    for IMG in "$BOOT_IMG" "$RECOVERY_IMG" "$VENDOR_BOOT_IMG" "$INIT_BOOT_IMG" "$SUPER_EMPTY_IMG"; do
        if [ -f "$IMG" ]; then
            IMG_NAME=$(basename "$IMG")
            IMG_URL=$(gofile_upload "$IMG")
            if [[ "$IMG_URL" == http* ]]; then
                IMG_LINKS="${IMG_LINKS}📎 <b>${IMG_NAME}:</b> ${IMG_URL}"$'\n'
            fi
        fi
    done

    MD5_FILE="${ZIP_FILE}.md5sum"
    if [ -f "$MD5_FILE" ]; then
        MD5=$(cat "$MD5_FILE" | awk '{print $1}')
    else
        MD5=$(md5sum "$ZIP_FILE" | awk '{print $1}')
    fi

    if [ -z "$DOWNLOAD_URL" ] || [[ "$DOWNLOAD_URL" != http* ]]; then
        tg_send "⚠️ <b>${LOG_TAG}</b>
Build succeeded but GoFile upload failed.
<b>File:</b> <code>$(basename $ZIP_FILE)</code>"
    else
        tg_send "✅ <b>${LOG_TAG} — BUILD COMPLETE</b>

📱 <b>Device:</b> OnePlus Nord 4 (avalon)
🍽️ <b>Build:</b> <code>brunch ${DEVICE}</code>
📦 <b>File:</b> <code>$(basename $ZIP_FILE)</code>
💾 <b>Size:</b> ${ZIP_SIZE}
🔑 <b>MD5:</b> <code>${MD5}</code>
⏱️ <b>Build Time:</b> $(elapsed)

🔗 <b>Download (ZIP):</b> ${DOWNLOAD_URL}

${IMG_LINKS}"
    fi

else
    tg_send "❌ <b>${LOG_TAG} — BUILD FAILED</b>

<b>Exit Code:</b> <code>${BUILD_STATUS}</code>
⏱️ <b>Elapsed:</b> $(elapsed)

Check Crave logs at: https://foss.crave.io"
    exit $BUILD_STATUS
fi

echo "Done! Elapsed: $(elapsed)"
