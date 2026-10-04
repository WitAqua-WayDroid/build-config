#!/bin/bash
#
# WitAqua WayDroid build: WitAqua plus the WitAqua-WayDroid local manifest,
# built as waydroid system and vendor images, zipped, uploaded and published
# on the WitAqua-WayDroid OTA channel.
#
# Environment (from the pipeline):
#   VERSION       WitAqua version / manifest branch, e.g. 16.2
#   DEVICE        waydroid product, e.g. waydroid_x86_64, waydroid_tv_x86_64
#   VARIANT       GAPPS or VANILLA
#   TYPE          build variant (userdebug)
#   UPLOAD_VENDOR upload the vendor image too (default: true for VANILLA)
#
# Overridable:
#   TREE                 source tree (default /ssd02/WitAqua/${VERSION}-waydroid)
#   LOCAL_MANIFEST_BRANCH  WitAqua-WayDroid/local_manifests branch (default ${VERSION})
#   UPLOAD_DEST          rsync/ssh destination for the zips
#   DOWNLOAD_BASE        public URL that UPLOAD_DEST is served at
#   OTA_REPO             git URL of the OTA channel repository
set -eo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo "--- Setup"
: "${VERSION:?VERSION is required}"
: "${DEVICE:?DEVICE is required}"
: "${VARIANT:?VARIANT is required (GAPPS or VANILLA)}"
TYPE=${TYPE:-userdebug}
case $VARIANT in
    GAPPS) export ANDROID_USE_GAPPS=true; UPLOAD_VENDOR=${UPLOAD_VENDOR:-false} ;;
    VANILLA) export ANDROID_USE_GAPPS=false; UPLOAD_VENDOR=${UPLOAD_VENDOR:-true} ;;
    *) echo "Unknown VARIANT $VARIANT"; exit 1 ;;
esac

TREE=${TREE:-/ssd02/WitAqua/${VERSION}-waydroid}
LOCAL_MANIFEST_BRANCH=${LOCAL_MANIFEST_BRANCH:-$VERSION}
UPLOAD_DEST=${UPLOAD_DEST:-download@download.witaqua.org:/mnt/NS100/witaqua-waydroid}
DOWNLOAD_BASE=${DOWNLOAD_BASE:-https://download.witaqua.org/waydroid}
OTA_REPO=${OTA_REPO:-git@github.com:WitAqua-WayDroid/ota.git}
KEYS_REPO=${KEYS_REPO:-git@github.com:WitAqua-WayDroid/vendor_witaqua-waydroid-priv_keys.git}

export USE_CCACHE=1
export CCACHE_EXEC=/usr/bin/ccache
export CCACHE_DIR=${CCACHE_DIR:-/ssd02/ccache}
ccache -M 200G
export WITAQUA_BUILD_TYPE=OFFICIAL
export WITAQUA_MAINTAINER=${WITAQUA_MAINTAINER:-WitAqua-WayDroid}
export PYTHONDONTWRITEBYTECODE=true
export BUILD_ENFORCE_SELINUX=1
export BUILD_NO=
unset BUILD_NUMBER
# mesa builds Rust parts (NVK) and runs rustc/bindgen/cbindgen from here.
export PATH=$HOME/.cargo/bin:$PATH

export BUILD_DATE=$(date +%Y%m%d)
export BUILD_UUID=${BUILD_UUID:-${BUILDKITE_BUILD_ID:-$(uuidgen 2>/dev/null)}}
export BUILD_NUMBER=$((10000000 + ${BUILDKITE_BUILD_NUMBER:-0}))
if [ -z "$BUILD_USER" ]; then
    export BUILD_USER=${BUILDKITE_BUILD_CREATOR:-Automatically}
fi
REPO_VERSION=${REPO_VERSION:-v2.50.1}
SYNC_LOG=/tmp/android-sync-${BUILD_UUID}.log
BUILD_LOG=/tmp/android-build-${BUILD_UUID}.log
rm -f /tmp/android-*.log || true

notify() {  # notify <markdown>
    [ -n "$WEBHOOK_URL" ] || return 0
    curl -sS -X POST -H "Content-Type: application/json" \
        -d "$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$1")" \
        "$WEBHOOK_URL" >/dev/null || true
}
notify "## Starting WayDroid build
- User: **$BUILD_USER**
- VERSION: **$VERSION**
- DEVICE: **$DEVICE** ($VARIANT)
- UUID: \`$BUILD_UUID\`
Check: [**Buildkite**]($BUILDKITE_BUILD_URL)"

echo "--- Syncing"
mkdir -p "$TREE"
cd "$TREE"
rm -rf .repo/local_manifests
mkdir -p .repo/local_manifests
curl -fsSL "https://raw.githubusercontent.com/WitAqua-WayDroid/local_manifests/${LOCAL_MANIFEST_BRANCH}/waydroid.xml" \
    -o .repo/local_manifests/waydroid.xml
# catch SIGPIPE from yes
yes | repo init -u https://github.com/WitAqua/manifest.git -b "$VERSION" -g default,-darwin,-muppets \
    --repo-rev="$REPO_VERSION" --git-lfs --no-clone-bundle || if [[ $? -eq 141 ]]; then true; else false; fi
repo version
repo forall -c "git reset -q --hard && git clean -qfdx" || true
for i in 1 2 3; do
    echo "Sync attempt $i..."
    repo sync --detach --current-branch --no-tags --force-remove-dirty --force-sync -j12 2>&1 | tee "$SYNC_LOG" && break
done
repo forall -vpc "if [ -f .gitattributes ]; then git lfs pull; fi" 2>&1 | tee -a "$SYNC_LOG" || true

# Signed with the WitAqua-WayDroid keys, read by vendor/witaqua/config/common.mk.
rm -rf vendor/witaqua-priv/keys
git clone -q --depth 1 "$KEYS_REPO" vendor/witaqua-priv/keys

. build/envsetup.sh 2>&1 || true

echo "--- Cleanup"
rm -rf out*

echo "--- Run breakfast"
breakfast "$DEVICE" "$TYPE"
if [[ "$TARGET_PRODUCT" != lineage_* ]]; then
    echo "breakfast failed, aborting..."
    exit 1
fi

echo "--- Building"
mka systemimage vendorimage 2>&1 | tee "$BUILD_LOG"

echo "--- Packaging"
OUT=$TREE/out/target/product/$DEVICE
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
NAME=WitAqua-WayDroid-${VERSION}-${BUILD_DATE}
SYSTEM_ZIP=${NAME}-${VARIANT}-${DEVICE}-system.zip
VENDOR_ZIP=${NAME}-MAINLINE-${DEVICE}-vendor.zip
(cd "$OUT" && zip -q -1 "$STAGE/$SYSTEM_ZIP" system.img)
[ "$UPLOAD_VENDOR" = true ] && (cd "$OUT" && zip -q -1 "$STAGE/$VENDOR_ZIP" vendor.img)
ASB=$(sed -n 's/^ro.build.version.security_patch=//p' "$OUT/system/build.prop")
BUILT=$(sed -n 's/^ro.build.date.utc=//p' "$OUT/system/build.prop")

echo "--- Uploading"
rsync -avP --mkpath -e ssh "$STAGE/$SYSTEM_ZIP" "$UPLOAD_DEST/$VERSION/system/$DEVICE/"
[ "$UPLOAD_VENDOR" = true ] && rsync -avP --mkpath -e ssh "$STAGE/$VENDOR_ZIP" "$UPLOAD_DEST/$VERSION/vendor/$DEVICE/"

echo "--- Publishing OTA"
# waydroid looks up waydroid_<arch> in the channel it is pointed at, with no
# notion of a TV device, so TV images get a channel of their own.
ARCH=${DEVICE#waydroid_}; ARCH=${ARCH#tv_}; ARCH=${ARCH%_only}
CHANNEL=$VERSION
[[ $DEVICE == waydroid_tv_* ]] && CHANNEL=$VERSION-tv
OTA=$(mktemp -d)
git clone -q --depth 1 "$OTA_REPO" "$OTA"
python3 "$SCRIPT_DIR/ota.py" "$OTA/$CHANNEL/system/lineage/waydroid_$ARCH/$VARIANT.json" \
    "$STAGE/$SYSTEM_ZIP" "$DOWNLOAD_BASE/$VERSION/system/$DEVICE/$SYSTEM_ZIP" "$VARIANT" "$VERSION" "$ASB" "$BUILT"
if [ "$UPLOAD_VENDOR" = true ]; then
    python3 "$SCRIPT_DIR/ota.py" "$OTA/$CHANNEL/vendor/waydroid_$ARCH/MAINLINE.json" \
        "$STAGE/$VENDOR_ZIP" "$DOWNLOAD_BASE/$VERSION/vendor/$DEVICE/$VENDOR_ZIP" MAINLINE "$VERSION" "$ASB" "$BUILT"
fi
git -C "$OTA" add -A
git -C "$OTA" commit -q -m "$VERSION: $DEVICE $VARIANT $BUILD_DATE"
for i in 1 2 3; do
    git -C "$OTA" push -q origin HEAD && break
    git -C "$OTA" pull -q --rebase origin HEAD
done
rm -rf "$OTA"

notify "# Build Successfully!
- $DEVICE $VARIANT $BUILD_DATE
- UUID: \`$BUILD_UUID\`
Please check [**Buildkite**]($BUILDKITE_BUILD_URL)"

echo "--- Cleanup"
rm -rf "$TREE"/out*
