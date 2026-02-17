#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <release-name>" >&2
    exit 1
fi

name="$1"
name_raw="${name}.ndjson"
name_xz="${name_raw}.xz"
extreme_compression="false"

if [[ -n "${EXTREME_COMPRESSION:-}" ]]; then
    extreme_compression_lc=$(echo "$EXTREME_COMPRESSION" | tr '[:upper:]' '[:lower:]')
    case "$extreme_compression_lc" in
        1|true|yes|en|enable|enabled)
            extreme_compression="true"
            ;;
    esac
fi

if ! gh release view "$name" &>/dev/null; then
    echo "Error: Release '$name' does not exist." >&2
    exit 1
fi

asset_digest=$(gh api "repos/:owner/:repo/releases/tags/$name" \
  --jq '(.tag_name + ".ndjson.xz") as $n | .assets[] | select(.name == $n) | .digest')

if [[ -z "$asset_digest" ]]; then
    echo "Error: Release '$name' does not have a ${name}.ndjson.xz asset." >&2
    exit 1
fi

asset_hash="${asset_digest#sha256:}"

if [[ ! -f "$name_xz" || "$asset_hash" != "$(sha256sum "$name_xz" | awk '{print $1}')" ]]; then
    echo "Downloading asset for release '$name'..." >&2
    gh release download "$name" -p "$name_xz"
fi

echo "Decompressing asset for release '$name'..." >&2
if ! xz -dc "$name_xz" > "$name_raw"; then
    echo "Error: Decompression failed. Exiting without updating release." >&2
    exit 1
fi

hash_before=$(sha256sum "$name_raw" | awk '{print $1}')

echo "Running reCheck on release '$name'..." >&2
if ! node ./src/reCheck.js "$name_raw"; then
    echo "reCheck failed. Exiting without updating release." >&2
    exit 1
fi

hash_after=$(sha256sum "$name_raw" | awk '{print $1}')

if [[ "$hash_before" == "$hash_after" ]]; then
    echo "No changes detected after reCheck." >&2
    exit 0
fi

echo "Changes detected after reCheck. Compressing updated asset..." >&2
xz_comp_flag="-5"
if [[ "$extreme_compression" == "true" ]]; then
    xz_comp_flag="-9e"
fi
if ! xz "$xz_comp_flag" -c "$name_raw" > "$name_xz"; then
    echo "Error: Compression failed. Exiting without updating release." >&2
    exit 1
fi
echo "Uploading updated asset to GitHub Release..." >&2
gh release upload "$name" "$name_xz" --clobber
echo "Recheck complete for release '$name'." >&2
