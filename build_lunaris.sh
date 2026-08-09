#!/bin/bash

set -e

set -o allexport
source .env
set +o allexport

LUNCH_TARGET="lineage_avalon-bp4a-user"
DEVICE="avalon"
LOG="build.log"

START_TIME=$(date +%s)
LOG_TAG="Lunaris | avalon"

BUILD_CMD="m bacon"

tg_send() {
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="$1" > /dev/null
}

tg_send_file() {
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TG_CHAT_ID}" \
        -F document=@"$1" \
        -F caption="$2" > /dev/null
}

tg_send_with_button() {
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        -d text="$1" \
        -d reply_markup='{
          "inline_keyboard": [[
            {"text": "🔄 Refresh Info", "callback_data": "refresh"}
          ]]
        }' | jq -r '.result.message_id'
}

tg_edit_msg() {
    local MSG_ID="$1"
    local TEXT="$2"

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText" \
        -d chat_id="${TG_CHAT_ID}" \
        -d message_id="$MSG_ID" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        -d text="$TEXT" > /dev/null
}

tg_edit_with_button() {
    local MSG_ID="$1"
    local TEXT="$2"

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText" \
        -d chat_id="${TG_CHAT_ID}" \
        -d message_id="$MSG_ID" \
        -d parse_mode="HTML" \
        -d disable_web_page_preview="true" \
        -d text="$TEXT" \
        -d reply_markup='{
          "inline_keyboard": [[
            {"text": "🔄 Refresh Info", "callback_data": "refresh"}
          ]]
        }' > /dev/null
}

elapsed() {
    local ELAPSED=$(( $(date +%s) - START_TIME ))
    printf '%dh %dm %ds' $(( ELAPSED/3600 )) $(( (ELAPSED%3600)/60 )) $(( ELAPSED%60 ))
}

get_stats() {
    read -r _ u1 n1 s1 i1 w1 irq1 sirq1 st1 _ < /proc/stat
    sleep 1
    read -r _ u2 n2 s2 i2 w2 irq2 sirq2 st2 _ < /proc/stat

    idle1=$((i1 + w1))
    idle2=$((i2 + w2))

    total1=$((u1 + n1 + s1 + i1 + w1 + irq1 + sirq1 + st1))
    total2=$((u2 + n2 + s2 + i2 + w2 + irq2 + sirq2 + st2))

    diff_idle=$((idle2 - idle1))
    diff_total=$((total2 - total1))

    local CPU=0
    if [ "$diff_total" -gt 0 ]; then
        CPU=$(( 100 * (diff_total - diff_idle) / diff_total ))
    fi

    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    echo "$CPU|$MEM_USED|$MEM_TOTAL|$LOAD"
}

build_progress_text() {
    local STATS CPU MEM_USED MEM_TOTAL LOAD CONSOLE NOW_LOCAL

    STATS=$(get_stats)
    CPU=$(echo "$STATS" | cut -d'|' -f1)
    MEM_USED=$(echo "$STATS" | cut -d'|' -f2)
    MEM_TOTAL=$(echo "$STATS" | cut -d'|' -f3)
    LOAD=$(echo "$STATS" | cut -d'|' -f4)

    CONSOLE=$(grep -v '^\s*$' "$LOG" 2>/dev/null | tail -n1 | cut -c1-110)
    NOW_LOCAL=$(date +"%H:%M:%S")

    cat <<EOF
⚙️ <b>${LOG_TAG}</b>

💻 CPU: <code>${CPU}%</code>
💾 RAM: <code>${MEM_USED}MB / ${MEM_TOTAL}MB</code>
⚡ Load: <code>${LOAD}</code>

🕛 Elapsed: $(elapsed)
🔥 Status: Compiling...
📟 Console: <code>${CONSOLE}</code>

🔄 Last Refreshed: <code>${NOW_LOCAL}</code>
EOF
}

listen_refresh() {
    local OFFSET=0

    while true; do
        UPDATES=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${OFFSET}")
        COUNT=$(echo "$UPDATES" | jq '.result | length')

        if [ "$COUNT" -gt 0 ]; then
            for ((i=0; i<COUNT; i++)); do
                UPDATE=$(echo "$UPDATES" | jq -c ".result[$i]")

                UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
                OFFSET=$((UPDATE_ID + 1))

                CALLBACK=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
                MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')

                if [ "$CALLBACK" = "refresh" ] && [ -n "$MSG_ID" ]; then
                    CALLBACK_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')

                    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/answerCallbackQuery" \
                         -d callback_query_id="$CALLBACK_ID" > /dev/null

                    tg_edit_with_button "$MSG_ID" "$(build_progress_text)"
                fi
            done
        fi

        sleep 2
    done
}

gofile_upload() {
    local FILE_PATH="$1"
    local FILENAME=$(basename "$FILE_PATH")
    echo "[*] Fetching best GoFile server..." >&2
    local SERVER=$(curl -s "https://api.gofile.io/servers" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['servers'][0]['name'], end='')")
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
<b>Target:</b> <code>${LUNCH_TARGET}</code>
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S UTC')"

echo "════════════════════════════════════"
echo "  Lunaris Build — OnePlus Nord 4"
echo "════════════════════════════════════"

rm -rf .repo/local_manifests/
echo "[*] Setting up local manifests..."
mkdir -p .repo/local_manifests

cat > .repo/local_manifests/lunaris_avalon.xml << 'LOCALMANIFEST'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="sathiya"
          fetch="https://github.com/SathiyaSenpai" />
  <remote name="lineage"
          fetch="https://github.com/LineageOS" />
  <remote name="avalon-stuffs"
          fetch="https://github.com/avalon-stuffs" />
  <remote name="source"
          fetch="https://github.com/SenpaiSource" />

  <project name="android_device_oneplus_avalon"
           path="device/oneplus/avalon"
           remote="sathiya"
           revision="luna-16.2" />
  <project name="android_device_oneplus_sm8650-common"
           path="device/oneplus/sm8650-common"
           remote="sathiya"
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
           remote="sathiya"
           revision="16.2" />
  <project name="proprietary_vendor_oneplus_sm8650-common"
           path="vendor/oneplus/sm8650-common"
           remote="sathiya"
           revision="16.2" />
  <project name="android_hardware_oplus"
           path="hardware/oplus"
           remote="sathiya"
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

  <remove-project name="Lunaris-AOSP/vendor_lineage" />
  <remove-project name="Lunaris-AOSP/frameworks_base" />
  <remove-project name="Lunaris-AOSP/packages_apps_Updater" />
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
</manifest>
LOCALMANIFEST

repo init -u https://github.com/Lunaris-AOSP/android -b 16.2 --git-lfs --depth=1

echo "[*] Syncing sources..."
tg_send "🔄 <b>${LOG_TAG}</b>
<b>Status:</b> Syncing sources..."

/opt/crave/resync.sh 2>&1

echo "[*] Cloning private lineage-priv..."
rm -rf vendor/lineage-priv
git clone "https://${GH_TOKEN}@github.com/SathiyaSenpai/lineage-priv.git" -b main vendor/lineage-priv

echo "[*] Sync complete."
tg_send "✅ <b>${LOG_TAG}</b>
<b>Status:</b> Sync done, starting compilation..."

echo "[*] Setting up build environment..."
source build/envsetup.sh

echo "[*] Lunching target: ${LUNCH_TARGET}"
lunch "${LUNCH_TARGET}"

m installclean

touch "$LOG"

PROGRESS_MSG_ID=$(tg_send_with_button "⚙️ <b>${LOG_TAG}</b>
🔥 Status: Compiling...
🔄 Tap Refresh Info to refresh build stats!")

listen_refresh &
LISTENER_PID=$!

echo "[*] Building..."
${BUILD_CMD} 2>&1 | tee "$LOG"
BUILD_STATUS=${PIPESTATUS[0]}

kill "$LISTENER_PID" 2>/dev/null
wait "$LISTENER_PID" 2>/dev/null

if [ $BUILD_STATUS -eq 0 ]; then
    tg_edit_msg "$PROGRESS_MSG_ID" "⚙️ <b>${LOG_TAG}</b>
🔥 Status: ✅ Success
🕛 Time: $(elapsed)"

    OUT_DIR="out/target/product/${DEVICE}"

    mapfile -t ZIP_CANDIDATES < <(compgen -G "${OUT_DIR}/Lunaris-*.zip"; compgen -G "${OUT_DIR}/*${DEVICE}*.zip")
    mapfile -t ZIP_CANDIDATES < <(printf '%s\n' "${ZIP_CANDIDATES[@]}" | grep -v "ota_update" | sort -u)

    BOOT_IMG="${OUT_DIR}/boot.img"
    RECOVERY_IMG="${OUT_DIR}/recovery.img"
    VENDOR_BOOT_IMG="${OUT_DIR}/vendor_boot.img"
    DTBO_IMG="${OUT_DIR}/dtbo.img"

    if [ "${#ZIP_CANDIDATES[@]}" -eq 0 ]; then
        tg_send "⚠️ <b>${LOG_TAG}</b>
Build succeeded but ZIP not found in <code>${OUT_DIR}</code>
Elapsed: $(elapsed)"
        exit 1
    fi

    ZIP_FILE="${ZIP_CANDIDATES[0]}"
    ZIP_SIZE=$(du -sh "$ZIP_FILE" | cut -f1)

    tg_send "📦 <b>${LOG_TAG}</b>
<b>Status:</b> Uploading to GoFile...
<b>File:</b> <code>$(basename $ZIP_FILE)</code>
<b>Size:</b> ${ZIP_SIZE}
<b>Elapsed:</b> $(elapsed)"

    DOWNLOAD_URL=$(gofile_upload "$ZIP_FILE")

    IMG_LINKS=""
    for IMG in "$BOOT_IMG" "$RECOVERY_IMG" "$VENDOR_BOOT_IMG" "$DTBO_IMG"; do
        if [ -f "$IMG" ]; then
            IMG_NAME=$(basename "$IMG")
            IMG_URL=$(gofile_upload "$IMG")
            if [[ "$IMG_URL" == http* ]]; then
                IMG_LINKS="${IMG_LINKS}📎 <b>${IMG_NAME}:</b> ${IMG_URL}\n"
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
🍽️ <b>Lunch:</b> <code>${LUNCH_TARGET}</code>
📦 <b>File:</b> <code>$(basename $ZIP_FILE)</code>
💾 <b>Size:</b> ${ZIP_SIZE}
🔑 <b>MD5:</b> <code>${MD5}</code>
⏱️ <b>Build Time:</b> $(elapsed)

🔗 <b>Download (ZIP):</b> ${DOWNLOAD_URL}

$(echo -e "$IMG_LINKS")"
    fi

else
    tg_edit_msg "$PROGRESS_MSG_ID" "⚙️ <b>${LOG_TAG}</b>
🔥 Status: ❌ Failed
🕛 Time: $(elapsed)"

    tg_send "❌ <b>${LOG_TAG} — BUILD FAILED</b>

<b>Exit Code:</b> <code>${BUILD_STATUS}</code>
⏱️ <b>Elapsed:</b> $(elapsed)

Check Crave logs at: https://foss.crave.io"

    if [ -f "out/error.log" ]; then
        tg_send_file "out/error.log" "📜 Build Error Log — ${DEVICE}"
    else
        tail -n 120 "$LOG" > error_tail.log
        tg_send_file "error_tail.log" "📜 Last 120 lines — ${DEVICE} (no out/error.log found)"
        rm -f error_tail.log
    fi

    exit $BUILD_STATUS
fi

echo "Done! Elapsed: $(elapsed)"
