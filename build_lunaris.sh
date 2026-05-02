#!/bin/bash
set -o pipefail

if [ -f .env ]; then
    set -o allexport
    source .env
    set +o allexport
else
    echo "❌ ERROR: .env file not found!"
    echo ""
    echo "Fix: connect to devspace and run:"
    echo "  cat > .env << 'EOF'"
    echo "  BOT=\"your_telegram_bot_token\""
    echo "  CHAT=\"your_log_chat_id\""
    echo "  UPLOAD=\"your_upload_chat_id\""
    echo "  GITHUB_PAT=\"your_github_token\""
    echo "  PIXELDRAIN=\"your_pixeldrain_key\""
    echo "  EOF"
    exit 1
fi

# ================= TIMEZONE =================
echo "🕒 Switching system timezone to Asia/Kolkata (IST)"
sudo rm -f /etc/localtime
sudo ln -s /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
echo "🕒 Current system time: $(date)"

# ================= JQ =================
if ! command -v jq &> /dev/null; then
    echo "📦 Installing jq..."
    mkdir -p ~/bin
    curl -fsSL -o ~/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux64
    chmod +x ~/bin/jq
    export PATH=$HOME/bin:$PATH
fi

# ================= CONFIGS =================
ROM_NAME="LunarisAOSP"
DEVICE="avalon"
BUILD_VARIANT="user"
ANDROID_VERSION="Android 16"
PROJECT_VERSION="16.2"
MAINTAINER="Sathiya"

OUT_DIR="out/target/product/${DEVICE}"
START_TIME=$(date +%s)
BUILD_LOG="build.log"
ERROR_LOG="out/error.log"

# ================= TELEGRAM =================
tg_send() {
    curl -s -X POST "https://api.telegram.org/bot${BOT}/sendMessage" \
        --data-urlencode "chat_id=${CHAT}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "text=$1" >/dev/null
}

tg_upload() {
    curl -s -X POST "https://api.telegram.org/bot${BOT}/sendMessage" \
        --data-urlencode "chat_id=${UPLOAD}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "disable_web_page_preview=true" \
        --data-urlencode "text=$1" >/dev/null
}

# ================= PIXELDRAIN =================
pixeldrain_upload() {
    local FILE="$1"
    if [ -f "$FILE" ]; then
        RESPONSE=$(curl -s -u ":$PIXELDRAIN" -F "file=@$FILE" https://pixeldrain.com/api/file)
        FILE_ID=$(echo "$RESPONSE" | jq -r '.id')
        if [[ "$FILE_ID" != "null" && -n "$FILE_ID" ]]; then
            echo "https://pixeldrain.com/u/$FILE_ID"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

# ================= GOFILE =================
gofile_upload() {
    local FILE="$1"

    mapfile -t SERVERS < <(curl -s https://api.gofile.io/servers | jq -r '.data.servers[].name')

    for S in $(printf "%s\n" "${SERVERS[@]}" | shuf); do
        RESP=$(curl -s -F "file=@${FILE}" "https://${S}.gofile.io/uploadFile")
        LINK=$(echo "$RESP" | jq -r '.data.downloadPage // empty')
        if [ -n "$LINK" ]; then
            echo "$LINK"
            return
        fi
    done

    echo ""
}

# ================= FAIL =================
on_fail() {
    echo "💥 Build failed. Collecting logs..."
    ERR_LINK=""
    BUILD_LINK=""

    [ -f "$ERROR_LOG" ] && ERR_LINK=$(gofile_upload "$ERROR_LOG")
    [ -f "$BUILD_LOG" ] && BUILD_LINK=$(gofile_upload "$BUILD_LOG")

    HEADER_MSG="✧ Build failed ✧
🧩 ${DEVICE} | ${BUILD_VARIANT} | ${ANDROID_VERSION}
"
    LOG_MSG=""
    [ -n "$ERR_LINK" ]   && LOG_MSG="${LOG_MSG}
⋄ [Error Log](${ERR_LINK})"
    [ -n "$BUILD_LINK" ] && LOG_MSG="${LOG_MSG}
⋄ [Build Log](${BUILD_LINK})"
    [ -n "$LOG_MSG" ]    && LOG_MSG="╭─ 📜 LOGS${LOG_MSG}"

    tg_upload "${HEADER_MSG}${LOG_MSG}"
    tg_send "💥 *Compilation failed, check build logs*"

    exit 1
}

# ================= BUILD START =================
tg_send "🌙 *${ROM_NAME}* buildbot triggered
🧩 *${DEVICE}* | *${ANDROID_VERSION}* | *${PROJECT_VERSION}*
🧪 Type: *${BUILD_VARIANT}*
🌏 _$(date +"%d %b %Y %I:%M %p IST")_"

# ================= CLEAN =================
echo ">>>> [STEP] Clean"
rm -rf .repo/local_manifests \
       vendor/avalon-priv

# ================= REPO INIT =================
echo ">>>> [STEP] Repo Init"
repo init --no-repo-verify --git-lfs \
    -u https://github.com/Lunaris-AOSP/android.git \
    -b 16.2 \
    -g default,-mips,-darwin,-notdefault

# ================= LOCAL MANIFESTS =================
echo ">>>> [STEP] Local Manifests"
git clone https://github.com/SathiyaSenpai/lunaris_local_manifests \
    --depth 1 -b lunaris .repo/local_manifests

# ================= REPO SYNC =================
echo ">>>> [STEP] Repo Sync"
if [ -f /opt/crave/resync.sh ]; then
    /opt/crave/resync.sh
else
    repo sync -c --force-sync --no-tags --no-clone-bundle -j$(nproc --all)
fi

# ================= SIGNING KEYS =================
echo ">>>> [STEP] Clone signing keys (avalon-priv)"
git clone https://${GITHUB_PAT}@github.com/SathiyaSenpai/avalon-priv.git \
    --depth 1 vendor/avalon-priv

# ================= BUILD SETUP =================
echo ">>>> [STEP] Setup build environment"
. build/envsetup.sh
lunch lineage_avalon-bp4a-user
export BUILD_USERNAME=sathiyasenpai
export BUILD_HOSTNAME=crave
mka installclean

# ================= BUILD =================
echo ">>>> [STEP] Building"
mka bacon 2>&1 | tee "$BUILD_LOG"

if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    on_fail
fi

if grep -q -E "ninja failed|failed to build some targets" "$BUILD_LOG"; then
    on_fail
fi

# ================= SUCCESS =================
END_TIME=$(date +%s)
DUR=$((END_TIME - START_TIME))

ROM_ZIP=$(ls -t ${OUT_DIR}/*.zip 2>/dev/null | head -n 1)

if [ -n "$ROM_ZIP" ]; then
    BUILD_ID=$(basename "$ROM_ZIP" .zip)
    ROM_SIZE=$(du -h "$ROM_ZIP" | awk '{print $1}')

    tg_send "✧ *Buildbot finished its job* ✧
🆔: \`${BUILD_ID}\`
🪶 Build Size: *${ROM_SIZE}*
🧑‍💻 \`${MAINTAINER}\`
⏳ _Compilation took $((DUR/3600))h $(((DUR%3600)/60))min_"

    tg_send "🌙 _The moon has spoken. Uploading artifacts…_"
fi

# ================= UPLOAD =================
echo ">>>> [STEP] Upload Artifacts"

HEADER_MSG="✧ ${ROM_NAME} Artifacts ✧
────────────────
🧩 ${DEVICE} | ${BUILD_VARIANT} | ${ANDROID_VERSION}
🆔: \`${BUILD_ID}\`
"

UPLOAD_MSG=""
IMG_MSG=""

if [ -n "$ROM_ZIP" ]; then
    GO_URL=$(gofile_upload "$ROM_ZIP")
    PD_URL=$(pixeldrain_upload "$ROM_ZIP")

    UPLOAD_MSG="${UPLOAD_MSG}
╭─ 📦 ROM
⋄ [GoFile](${GO_URL})
⋄ [PixelDrain](${PD_URL})
"
fi

for IMG in boot.img vendor_boot.img init_boot.img super_empty.img recovery.img; do
    FILE="${OUT_DIR}/${IMG}"
    if [ -f "$FILE" ]; then
        GO_URL=$(gofile_upload "$FILE")
        IMG_MSG="${IMG_MSG}
⋄ [${IMG}](${GO_URL})"
    fi
done

OTA_JSON="${OUT_DIR}/${DEVICE}.json"
if [ -f "$OTA_JSON" ]; then
    GO_URL=$(gofile_upload "$OTA_JSON")
    IMG_MSG="${IMG_MSG}

╭─ 📜 OTA
⋄ [OTA JSON](${GO_URL})"
fi

[ -n "$IMG_MSG" ] && IMG_MSG="╭─ 🧩 IMAGES${IMG_MSG}"

FINAL_MESSAGE="${HEADER_MSG}${UPLOAD_MSG}${IMG_MSG}"

tg_upload "$FINAL_MESSAGE"
tg_send "🌙 _Artifacts released under the moonlight._"
