#!/bin/bash

set -e

# CONFIG
TG_BOT_TOKEN="8640370988:AAGXrskkxQYom0H0loYQsD7jh-EaVvcIxZw"
TG_CHAT_ID="-1003917803238"
ROM_MANIFEST="https://github.com/Lunaris-AOSP/android"
ROM_BRANCH="16.2"
LUNCH_TARGET="lineage_avalon-bp4a-user" 
BUILD_CMD="m bacon"
DEVICE="avalon"

START_TIME=$(date +%s)
LOG_TAG="Lunaris | avalon"

# Telegram
tg_send() {
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" > /dev/null
}

tg_send_file() {
    local FILE="$1"
    local CAPTION="$2"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"$FILE" \
        -F caption="$CAPTION" \
        -F parse_mode="HTML" > /dev/null
}

elapsed() {
    local ELAPSED=$(( $(date +%s) - START_TIME ))
    printf '%dh %dm %ds' $(( ELAPSED/3600 )) $(( (ELAPSED%3600)/60 )) $(( ELAPSED%60 ))
}

# GoFile upload
gofile_upload() {
    local FILE_PATH="$1"
    local FILENAME=$(basename "$FILE_PATH")

    echo "[*] Fetching best GoFile server..."
    local SERVER=$(curl -s "https://api.gofile.io/servers" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['servers'][0]['name'])")

    if [ -z "$SERVER" ]; then
        echo "[!] Could not get GoFile server, falling back to store1"
        SERVER="store1"
    fi

    echo "[*] Uploading $FILENAME to GoFile server: $SERVER"
    local UPLOAD_RESPONSE=$(curl -s \
        -F "file=@${FILE_PATH}" \
        "https://${SERVER}.gofile.io/contents/uploadfile")

    echo "$UPLOAD_RESPONSE"
    local DOWNLOAD_URL=$(echo "$UPLOAD_RESPONSE" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['downloadPage'])" 2>/dev/null)

    echo "$DOWNLOAD_URL"
}

# Notify build started
tg_send "🔨 <b>${LOG_TAG}</b>
<b>Status:</b> Build started
<b>Target:</b> <code>${LUNCH_TARGET}</code>
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S UTC')"

echo "════════════════════════════════════"
echo "  Luna Build — OnePlus Nord 4"
echo "════════════════════════════════════"

# repo init
echo "[*] Initializing repo..."
repo init -u "${ROM_MANIFEST}" -b "${ROM_BRANCH}" --git-lfs --depth=1 2>&1

# Clone device trees via local manifest
echo "[*] Setting up local manifests..."
mkdir -p .repo/local_manifests

cat > .repo/local_manifests/aviumui_avalon.xml << 'LOCALMANIFEST'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="sathiya"
          fetch="https://github.com/SathiyaSenpai" />
  <remote name="lineage"
          fetch="https://github.com/LineageOS" />
  <project name="android_device_oneplus_avalon"
           path="device/oneplus/avalon"
           remote="sathiya"
           revision="lunaris" />
  <project name="android_device_oneplus_sm8650-common"
           path="device/oneplus/sm8650-common"
           remote="sathiya"
           revision="lineage-23.2" />
  <project name="android_kernel_oneplus_sm8650"
           path="kernel/oneplus/sm8650"
           remote="sathiya"
           revision="lineage-23.2" />
  <project name="android_kernel_oneplus_sm8650-modules"
           path="kernel/oneplus/sm8650-modules"
           remote="sathiya"
           revision="lineage-23.2" />
  <project name="android_kernel_oneplus_sm8650-devicetrees"
           path="kernel/oneplus/sm8650-devicetrees"
           remote="sathiya"
           revision="lineage-23.2" />
  <project name="proprietary_vendor_oneplus_avalon"
           path="vendor/oneplus/avalon"
           remote="sathiya"
           revision="lineage-23.2" />
  <project name="proprietary_vendor_oneplus_sm8650-common"
           path="vendor/oneplus/sm8650-common"
           remote="sathiya"
           revision="lineage-23.2" />
  <project name="android_hardware_oplus"
           path="hardware/oplus"
           remote="sathiya"
           revision="lineage-23.2" />
  <project name="android_hardware_dolby_interfaces"
           path="hardware/dolby/interfaces"
           remote="lineage"
           revision="lineage-23.2" />
  <project name="android_hardware_dolby"
           path="hardware/dolby"
           remote="sathiya"
           revision="16.0" />
  <project name="lineage-priv"
           path="vendor/lineage-priv"
           remote="sathiya"
           revision="main" />
</manifest>
LOCALMANIFEST

echo "[*] Local manifest written."

# Step 4: repo sync
echo "[*] Syncing sources..."
tg_send "🔄 <b>${LOG_TAG}</b>
<b>Status:</b> Syncing sources..."

/opt/crave/resync.sh 2>&1

echo "[*] Sync complete."
tg_send "✅ <b>${LOG_TAG}</b>
<b>Status:</b> Sync done, starting compilation..."

# Step 5: Build
echo "[*] Setting up build environment..."
source build/envsetup.sh

echo "[*] Lunching target: ${LUNCH_TARGET}"
lunch "${LUNCH_TARGET}"

echo "[*] Building..."
${BUILD_CMD} 2>&1

BUILD_STATUS=$?

# Step 6: Upload & Notify
if [ $BUILD_STATUS -eq 0 ]; then
    echo "[*] Build succeeded! Looking for output files..."

    OUT_DIR="out/target/product/${DEVICE}"

    # Find ZIP (fixed with proper parentheses)
    ZIP_FILE=$(find "${OUT_DIR}" -maxdepth 1 \( -name "Lunaris-*.zip" -o -name "*${DEVICE}*.zip" \) \
               2>/dev/null | grep -v "ota_update" | head -1)

    # Find boot/recovery/vendor_boot images
    BOOT_IMG="${OUT_DIR}/boot.img"
    RECOVERY_IMG="${OUT_DIR}/recovery.img"
    VENDOR_BOOT_IMG="${OUT_DIR}/vendor_boot.img"
    DTBO_IMG="${OUT_DIR}/dtbo.img"

    if [ -z "$ZIP_FILE" ]; then
        echo "[!] Could not find output ZIP in ${OUT_DIR}"
        tg_send "⚠️ <b>${LOG_TAG}</b>
Build succeeded but ZIP not found in <code>${OUT_DIR}</code>
Elapsed: $(elapsed)"
        exit 1
    fi

    ZIP_SIZE=$(du -sh "$ZIP_FILE" | cut -f1)
    echo "[*] Found ZIP: $ZIP_FILE (${ZIP_SIZE})"

    tg_send "📦 <b>${LOG_TAG}</b>
<b>Status:</b> Build done! Uploading to GoFile...
<b>File:</b> <code>$(basename $ZIP_FILE)</code>
<b>Size:</b> ${ZIP_SIZE}
<b>Elapsed:</b> $(elapsed)"

    # Upload ZIP
    DOWNLOAD_URL=$(gofile_upload "$ZIP_FILE" | tail -1)

    # Upload images if they exist
    IMG_LINKS=""
    for IMG in "$BOOT_IMG" "$RECOVERY_IMG" "$VENDOR_BOOT_IMG" "$DTBO_IMG"; do
        if [ -f "$IMG" ]; then
            IMG_NAME=$(basename "$IMG")
            echo "[*] Uploading $IMG_NAME..."
            IMG_URL=$(gofile_upload "$IMG" | tail -1)
            if [[ "$IMG_URL" == http* ]]; then
                IMG_LINKS="${IMG_LINKS}📎 <b>${IMG_NAME}:</b> ${IMG_URL}\n"
                echo "[*] $IMG_NAME uploaded: $IMG_URL"
            fi
        fi
    done

    # MD5
    MD5_FILE="${ZIP_FILE}.md5sum"
    MD5=""
    if [ -f "$MD5_FILE" ]; then
        MD5=$(cat "$MD5_FILE" | awk '{print $1}')
    else
        MD5=$(md5sum "$ZIP_FILE" | awk '{print $1}')
    fi

    if [ -z "$DOWNLOAD_URL" ] || [[ "$DOWNLOAD_URL" != http* ]]; then
        tg_send "⚠️ <b>${LOG_TAG}</b>
Build succeeded but GoFile ZIP upload failed.
<b>File:</b> <code>$(basename $ZIP_FILE)</code>"
    else
        tg_send "✅ <b>${LOG_TAG} — BUILD COMPLETE</b>

📱 <b>Device:</b> OnePlus Nord 4 (avalon)
🍽️ <b>Lunch:</b> <code>${LUNCH_TARGET}</code>
📦 <b>File:</b> <code>$(basename $ZIP_FILE)</code>
💾 <b>Size:</b> ${ZIP_SIZE}
🔑 <b>MD5:</b> <code>${MD5}</code>
⏱️ <b>Build Time:</b> $(elapsed)

🔗 <b>Download (ZIP):</b> ${DOWNLOAD_URL}

${IMG_LINKS}"
    fi

else
    echo "[!] Build FAILED with exit code $BUILD_STATUS"
    tg_send "❌ <b>${LOG_TAG} — BUILD FAILED</b>

<b>Exit Code:</b> <code>${BUILD_STATUS}</code>
⏱️ <b>Elapsed:</b> $(elapsed)

Check Crave logs at: https://foss.crave.io"
    exit $BUILD_STATUS
fi

echo "Done! Elapsed: $(elapsed)"
