#!/bin/bash
# lunaris build script for nord 4 (avalon)

if [ ! -f .env ]; then
    echo ".env not found, make one first"
    exit 1
fi

set -o allexport
source .env
set +o allexport

LUNCH_TARGET="lineage_avalon-bp4a-user"
DEVICE="avalon"
OUT_DIR="out/target/product/${DEVICE}"
LOG="build.log"
LOG_TAG="Lunaris | avalon"
BUILD_CMD="m bacon"
START_TIME=$(date +%s)

API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
BUTTON='{"inline_keyboard":[[{"text":"Refresh Info","callback_data":"refresh"}]]}'

tg_send() {
    curl -s -X POST "$API/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="HTML" \
        --data-urlencode "text=$1" > /dev/null
}

tg_send_file() {
    curl -s -X POST "$API/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"$1" \
        -F caption="$2" > /dev/null
}

tg_send_with_button() {
    curl -s -X POST "$API/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        --data-urlencode "text=$1" \
        --data-urlencode "reply_markup=${BUTTON}" | jq -r '.result.message_id'
}

tg_edit_msg() {
    curl -s -X POST "$API/editMessageText" \
        -d chat_id="${TG_CHAT_ID}" \
        -d message_id="$1" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        --data-urlencode "text=$2" > /dev/null
}

tg_edit_with_button() {
    curl -s -X POST "$API/editMessageText" \
        -d chat_id="${TG_CHAT_ID}" \
        -d message_id="$1" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        --data-urlencode "text=$2" \
        --data-urlencode "reply_markup=${BUTTON}" > /dev/null
}

escape_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

elapsed() {
    local ELAPSED=$(( $(date +%s) - START_TIME ))
    printf '%dh %dm %ds' $(( ELAPSED/3600 )) $(( (ELAPSED%3600)/60 )) $(( ELAPSED%60 ))
}

build_progress_text() {
    CPU=$(vmstat 1 2 | tail -n 1 | awk '{print 100 - $15}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    CONSOLE=$(tail -c 3000 "$LOG" 2>/dev/null | tr '\r' '\n' | grep -v '^\s*$' | tail -n 1 | cut -c1-110 | escape_html)
    NOW=$(date +"%H:%M:%S")

    cat <<EOF
⚙️ <b>${LOG_TAG}</b>

CPU: <code>${CPU}%</code>
RAM: <code>${MEM_USED}MB / ${MEM_TOTAL}MB</code>
Load: <code>${LOAD}</code>

Elapsed: $(elapsed)
Status: Compiling...
Console: <code>${CONSOLE}</code>

Last refreshed: <code>${NOW}</code>
EOF
}

listen_refresh() {
    LAST_ID=$(curl -s "$API/getUpdates?offset=-1" | jq '.result[-1].update_id // 0')
    OFFSET=$((LAST_ID + 1))

    while true; do
        UPDATES=$(curl -s "$API/getUpdates?offset=${OFFSET}")
        COUNT=$(echo "$UPDATES" | jq '.result | length' 2>/dev/null || echo 0)

        for ((i=0; i<COUNT; i++)); do
            UPDATE=$(echo "$UPDATES" | jq -c ".result[$i]")
            UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
            OFFSET=$((UPDATE_ID + 1))

            CALLBACK=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
            MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')

            if [ "$CALLBACK" = "refresh" ] && [ -n "$MSG_ID" ]; then
                CALLBACK_ID=$(echo "$UPDATE" | jq -r '.callback_query.id')
                curl -s -X POST "$API/answerCallbackQuery" -d callback_query_id="$CALLBACK_ID" > /dev/null
                tg_edit_with_button "$MSG_ID" "$(build_progress_text)"
            fi
        done

        sleep 2
    done
}

gofile_upload() {
    FILE_PATH="$1"
    echo "uploading $(basename "$FILE_PATH") to gofile..." >&2

    if [ -n "$GOFILE_TOKEN" ]; then
        RESPONSE=$(curl -s -H "Authorization: Bearer ${GOFILE_TOKEN}" \
            -F "file=@${FILE_PATH}" "https://upload.gofile.io/uploadfile")
    else
        RESPONSE=$(curl -s -F "file=@${FILE_PATH}" "https://upload.gofile.io/uploadfile")
    fi

    echo "$RESPONSE" >&2
    echo "$RESPONSE" | jq -r '.data.downloadPage // empty'
}

tg_send "🔨 <b>${LOG_TAG}</b>
<b>Status:</b> Build started
<b>Target:</b> <code>${LUNCH_TARGET}</code>
<b>Time:</b> $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

echo "=== Lunaris build - OnePlus Nord 4 ==="

# deleting stuff i will download again in 5 minutes
echo "cleaning old dirs..."
rm -rf device/oneplus/avalon
rm -rf device/oneplus/sm8650-common
rm -rf vendor/oneplus/avalon
rm -rf vendor/oneplus/sm8650-common
rm -rf frameworks/base
rm -rf frameworks/av
rm -rf frameworks/native
rm -rf system/sepolicy
rm -rf build/soong
rm -rf vendor/lineage
rm -rf packages/apps/Updater

# dont need these anymore
rm -rf packages/apps/Aperture
rm -rf packages/apps/Glimpse

rm -rf .repo/local_manifests/

echo "making local manifest..."
mkdir -p .repo/local_manifests

cat > .repo/local_manifests/lunaris_avalon.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="lineage"
          fetch="https://github.com/LineageOS" />
  <remote name="avalon-stuffs"
          fetch="https://github.com/avalon-stuffs" />
  <remote name="source"
          fetch="https://github.com/SenpaiSource" />
  <remote name="klaus"
          fetch="https://gitea.com/EternalMikaelson" />

  <project name="android_device_oneplus_avalon"
           path="device/oneplus/avalon"
           remote="source"
           revision="luna-16.2" />
  <project name="android_device_oneplus_sm8650-common"
           path="device/oneplus/sm8650-common"
           remote="source"
           revision="lineage-23.2" />
  <project name="android_kernel_oneplus_sm8650"
           path="kernel/oneplus/sm8650"
           remote="source"
           revision="lineage-24.0" />
  <project name="android_kernel_oneplus_sm8650-modules"
           path="kernel/oneplus/sm8650-modules"
           remote="source"
           revision="lineage-24.0" />
  <project name="android_kernel_oneplus_sm8650-devicetrees"
           path="kernel/oneplus/sm8650-devicetrees"
           remote="source"
           revision="lineage-24.0" />
  <project name="proprietary_vendor_oneplus_avalon"
           path="vendor/oneplus/avalon"
           remote="source"
           revision="16.2" />
  <project name="proprietary_vendor_oneplus_sm8650-common"
           path="vendor/oneplus/sm8650-common"
           remote="source"
           revision="16.2" />
  <project name="android_hardware_oplus"
           path="hardware/oplus"
           remote="source"
           revision="lineage-23.2" />
  <project name="android_packages_apps_LunarisDolby"
           path="packages/apps"
           remote="avalon-stuffs"
           revision="16" />
  <project name="proprietary_vendor_sony_dolby"
           path="vendor/sony/dolby"
           remote="avalon-stuffs"
           revision="16" />
  <project name="proprietary_vendor_oneplus_ir"
           path="vendor/oneplus/ir"
           remote="avalon-stuffs"
           revision="16" />
  <project name="proprietary_vendor_oneplus_ltw"
           path="vendor/oneplus/ltw"
           remote="source"
           revision="16" />
  <project name="proprietary_vendor_oplus_camera"
           path="vendor/oplus/camera"
           remote="klaus"
           revision="16-avalon" />
  <project name="packages_apps_AxionWidgets"
           path="packages/apps/AxionWidgets"
           remote="source"
           revision="16" />

  <remove-project name="Lunaris-AOSP/vendor_lineage" />
  <remove-project name="Lunaris-AOSP/frameworks_base" />
  <remove-project name="Lunaris-AOSP/frameworks_av" />
  <remove-project name="Lunaris-AOSP/frameworks_native" />
  <remove-project name="Lunaris-AOSP/system_sepolicy" />
  <remove-project name="Lunaris-AOSP/build_soong" />
  <remove-project name="LineageOS/android_packages_apps_Aperture" />
  <remove-project name="LineageOS/android_packages_apps_Glimpse" />
  <remove-project name="Lunaris-AOSP/packages_apps_Updater" />
  <remove-project name="LineageOS/android_device_qcom_sepolicy_vndr" />
  <remove-project name="LineageOS/android_vendor_qcom_opensource_vibrator" />

  <project name="luna_packages_apps_Updater"
           path="packages/apps/Updater"
           remote="source"
           revision="16.2" />
  <project name="luna_vendor_lineage"
           path="vendor/lineage"
           remote="source"
           revision="16.2"
           clone-depth="1" />
  <project name="luna_frameworks_base"
           path="frameworks/base"
           remote="source"
           revision="16.2"
           clone-depth="1" />
  <project name="luna_frameworks_av"
           path="frameworks/av"
           remote="source"
           revision="16.2"
           clone-depth="1" />
  <project name="luna_frameworks_native"
           path="frameworks/native"
           remote="source"
           revision="16.2"
           clone-depth="1" />
  <project name="luna_system_sepolicy"
           path="system/sepolicy"
           remote="source"
           revision="16.2"
           clone-depth="1" />
  <project name="luna_build_soong"
           path="build/soong"
           remote="source"
           revision="16.2"
           clone-depth="1" />
  <project name="android_device_qcom_sepolicy_vndr"
           path="device/qcom/sepolicy_vndr/sm8650"
           remote="source"
           revision="lineage-23.2-caf-sm8650"
           clone-depth="1" />
</manifest>
EOF

repo init -u https://github.com/Lunaris-AOSP/android -b 16.2 --git-lfs --depth=1 || { tg_send "❌ <b>${LOG_TAG}</b>
repo init failed"; exit 1; }

echo "syncing sources..."
tg_send "🔄 <b>${LOG_TAG}</b>
<b>Status:</b> Syncing sources..."

/opt/crave/resync.sh 2>&1 || { tg_send "❌ <b>${LOG_TAG}</b>
Source sync failed"; exit 1; }

echo "cloning private repo..."
rm -rf vendor/lineage-priv

git clone "https://SathiyaSenpai:${MY_GH_TOKEN}@github.com/SathiyaSenpai/lineage-priv.git" -b main vendor/lineage-priv || { tg_send "❌ <b>${LOG_TAG}</b>
Failed to clone lineage-priv"; exit 1; }

echo "fetching LFS files for oplus camera..."
git -C vendor/oplus/camera lfs install
git -C vendor/oplus/camera lfs fetch
git -C vendor/oplus/camera lfs checkout || { tg_send "❌ <b>${LOG_TAG}</b>
LFS checkout failed for oplus camera"; exit 1; }

echo "sync done"
tg_send "✅ <b>${LOG_TAG}</b>
<b>Status:</b> Sync done, starting build..."

source build/envsetup.sh

echo "lunching ${LUNCH_TARGET}"
lunch "${LUNCH_TARGET}" || { tg_send "❌ <b>${LOG_TAG}</b>
lunch failed for ${LUNCH_TARGET}"; exit 1; }

m installclean

touch "$LOG"

PROGRESS_MSG_ID=$(tg_send_with_button "⚙️ <b>${LOG_TAG}</b>
Status: Compiling...
Tap Refresh Info to see build stats")

listen_refresh &
LISTENER_PID=$!

# if this fails i am going to sleep
echo "building..."
${BUILD_CMD} 2>&1 | tee "$LOG"
BUILD_STATUS=${PIPESTATUS[0]}

kill "$LISTENER_PID" 2>/dev/null
wait "$LISTENER_PID" 2>/dev/null

if [ $BUILD_STATUS -ne 0 ]; then
    tg_edit_msg "$PROGRESS_MSG_ID" "⚙️ <b>${LOG_TAG}</b>
Status: ❌ Failed
Time: $(elapsed)"

    tg_send "❌ <b>${LOG_TAG} - BUILD FAILED</b>

<b>Exit code:</b> <code>${BUILD_STATUS}</code>
<b>Elapsed:</b> $(elapsed)

Check crave logs: https://foss.crave.io"

    if [ -f "out/error.log" ]; then
        tg_send_file "out/error.log" "Build error log - ${DEVICE}"
    else
        tail -n 120 "$LOG" > error_tail.log
        tg_send_file "error_tail.log" "Last 120 lines - ${DEVICE} (no out/error.log)"
        rm -f error_tail.log
    fi

    exit $BUILD_STATUS
fi

tg_edit_msg "$PROGRESS_MSG_ID" "⚙️ <b>${LOG_TAG}</b>
Status: ✅ Success
Time: $(elapsed)"

ZIP_FILE=$(ls ${OUT_DIR}/Lunaris-*.zip 2>/dev/null | grep -v ota_update | head -n 1)
if [ -z "$ZIP_FILE" ]; then
    ZIP_FILE=$(ls ${OUT_DIR}/*${DEVICE}*.zip 2>/dev/null | grep -v ota_update | head -n 1)
fi

if [ -z "$ZIP_FILE" ]; then
    tg_send "⚠️ <b>${LOG_TAG}</b>
Build done but zip not found in <code>${OUT_DIR}</code>
Elapsed: $(elapsed)"
    exit 1
fi

ZIP_NAME=$(basename "$ZIP_FILE")
ZIP_SIZE=$(du -sh "$ZIP_FILE" | cut -f1)

tg_send "📦 <b>${LOG_TAG}</b>
<b>Status:</b> Uploading to GoFile...
<b>File:</b> <code>${ZIP_NAME}</code>
<b>Size:</b> ${ZIP_SIZE}
<b>Elapsed:</b> $(elapsed)"

DOWNLOAD_URL=$(gofile_upload "$ZIP_FILE")

IMG_LINKS=""
for IMG in boot recovery vendor_boot dtbo; do
    if [ -f "${OUT_DIR}/${IMG}.img" ]; then
        IMG_URL=$(gofile_upload "${OUT_DIR}/${IMG}.img")
        if [[ "$IMG_URL" == http* ]]; then
            IMG_LINKS="${IMG_LINKS}${IMG}.img: ${IMG_URL}"$'\n'
        fi
    fi
done

if [ -f "${ZIP_FILE}.md5sum" ]; then
    MD5=$(awk '{print $1}' "${ZIP_FILE}.md5sum")
else
    MD5=$(md5sum "$ZIP_FILE" | awk '{print $1}')
fi

if [[ "$DOWNLOAD_URL" != http* ]]; then
    tg_send "⚠️ <b>${LOG_TAG}</b>
Build done but gofile upload failed
<b>File:</b> <code>${ZIP_NAME}</code>"
else
    tg_send "✅ <b>${LOG_TAG} - BUILD COMPLETE</b>

<b>Device:</b> OnePlus Nord 4 (avalon)
<b>Lunch:</b> <code>${LUNCH_TARGET}</code>
<b>File:</b> <code>${ZIP_NAME}</code>
<b>Size:</b> ${ZIP_SIZE}
<b>MD5:</b> <code>${MD5}</code>
<b>Build time:</b> $(elapsed)

<b>Download (ZIP):</b> ${DOWNLOAD_URL}

${IMG_LINKS}"
fi

echo "Done! Elapsed: $(elapsed)"
