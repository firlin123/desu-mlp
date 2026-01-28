#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Configuration and Setup
# ==============================

REPO="${REPO:-firlin123/desu-mlp}"
local_file="desuarchive_mlp_full.ndjson"
attempt_repair=0

# ==============================
# Argument Parsing
# ==============================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--attempt-repair)
            attempt_repair=1
            shift
            ;;
        -*)
            echo "Usage: $0 [-r|--attempt-repair] [<local-ndjson-file>]" >&2
            exit 1
            ;;
        *)
            local_file="$1"
            shift
            ;;
    esac
done

local_dir="$(dirname "$local_file")"
base_url="https://github.com/$REPO/releases/download"
manifest_url="https://raw.githubusercontent.com/${REPO}/main/manifest.json"

# ==============================
# Dependency Check
# ==============================
required_cmds=(curl jq parallel gzip dd stat tail)

if [[ $attempt_repair -eq 1 ]]; then
    required_cmds+=(truncate)
fi

missing_cmds=()
for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_cmds+=("$cmd")
    fi
done

if [ ${#missing_cmds[@]} -ne 0 ]; then
    echo "Error: Missing required commands: ${missing_cmds[*]}" >&2
    exit 1
fi

# ==============================
# Download Manifest
# ==============================
if ! manifest_json="$(curl -fsSL "$manifest_url")"; then
    echo "Failed to download manifest.json from ${manifest_url}" >&2
    exit 1
fi

if ! last_remote_num="$(jq -r '.lastDownloaded' <<<"$manifest_json" 2>/dev/null)"; then
    echo "Downloaded manifest.json is invalid." >&2
    exit 1
fi

# ==============================
# Check Local Archive State
# ==============================
last_local_num=0
if [[ -f "$local_file" ]]; then
    if ! last_local_json="$(tail -n 1 "$local_file" 2>/dev/null)"; then
        echo "Failed to read local NDJSON file." >&2
        exit 1
    fi
    if ! last_local_num="$(jq -r '.num' <<<"$last_local_json" 2>/dev/null)"; then
        if [[ $attempt_repair -eq 0 ]]; then
            echo "Failed to parse local NDJSON file. If the process was interrupted, consider using the --attempt-repair (-r) to remove the last corrupted line." >&2
            exit 1
        fi
        echo "Attempting to repair local NDJSON file by removing the last line..." >&2
        last_line_len=$(wc -c < <(echo -n "$last_local_json"))
        file_size=$(stat -c%s "$local_file")
        trunc_size=$(( file_size - last_line_len ))
        if (( trunc_size < 0 )); then
            echo "Error: Cannot repair file; it may be too small or empty." >&2
            exit 1
        fi
        echo "Truncating file to $trunc_size bytes..." >&2
        truncate --size=$trunc_size "$local_file"
        exit 0
    fi
fi

# Define update range
update_start_num=$((last_local_num + 1))
update_end_num="$last_remote_num"

# ==============================
# Check for No Updates
# ==============================
if [[ $update_start_num -gt $update_end_num ]]; then
    echo "Local archive is already up to date. No updates needed." >&2
    exit 0
fi

# ==============================
# Parse Names and URLs from Manifest
# ==============================
readarray -t all_names < <(jq -r '((.yearly | map(.name)) + .monthly + .daily)[]' <<<"$manifest_json" 2>/dev/null)
readarray -t all_links < <(jq -r --arg base "$base_url" '((.yearly | map(.url)) + [(.monthly + .daily)[] | "\($base)/\(.)/\(.).ndjson.xz"])[]' <<<"$manifest_json" 2>/dev/null)

# Arrays for temporary download and extract tracking
queue_names=()
queue_links=()
queue_starts=()
queue_ends=()
queue_paths=()
queue_xz_paths=()

# Ensure temp files get cleaned up on exit
trap 'rm -f "${queue_xz_paths[@]}" "${queue_paths[@]}"' EXIT

# ==============================
# Validate Contiguity and Queue Needed Files
# ==============================
prev_end=-1
for i in "${!all_names[@]}"; do
    chunk_name="${all_names[i]}"
    chunk_link="${all_links[i]}"

    # Extract start/end post numbers from filenames
    if [[ "$chunk_name" =~ _([0-9]+)_([0-9]+)$ ]]; then
        chunk_start="${BASH_REMATCH[1]}"
        chunk_end="${BASH_REMATCH[2]}"
    else
        echo "Error: Invalid entry name '$chunk_name'." >&2
        exit 1
    fi

    # Ensure no gaps between chunks
    if [[ $prev_end -ne -1 && $((prev_end + 1)) -ne $chunk_start ]]; then
        echo "Error: Gap detected between entries $prev_end and $chunk_start." >&2
        exit 1
    fi
    prev_end=$chunk_end

    # Include only newer chunks
    if (( chunk_end >= update_start_num )); then
        queue_names+=("$chunk_name")
        queue_links+=("$chunk_link")
        queue_starts+=("$chunk_start")
        queue_ends+=("$chunk_end")
        queue_xz_paths+=("$(mktemp "${local_dir}/$chunk_name.ndjson.xz.tmp.XXXXXX")")
        queue_paths+=("$(mktemp "${local_dir}/$chunk_name.ndjson.tmp.XXXXXX")")
    fi
done

# ==============================
# Sequential Downloading
# ==============================
for i in "${!queue_names[@]}"; do
    chunk_name="${queue_names[i]}"
    chunk_link="${queue_links[i]}"
    xz_path="${queue_xz_paths[i]}"

    echo "Downloading $chunk_name from $chunk_link..."
    if ! curl -fL "$chunk_link" --retry 10 --retry-delay 60 --retry-all-errors -o "$xz_path" 2>&1; then
        echo "Failed to download $chunk_name from $chunk_link." >&2
        exit 1
    fi
    echo "Done downloading $chunk_name."
done

# ==============================
# Parallel Decompression
# ==============================
cores=$(nproc || echo 4)
if parallel -j "$cores" --halt now,fail=1 --ungroup --no-notice --plain '
    echo "Decompressing "{1}"..."
    if ! xz -dc {2} > {3} 2>/dev/null; then
        echo "Failed to decompress "{1}"."
        exit 1
    fi
    echo "Done decompressing "{1}"."
    rm -f {2}
' ::: "${queue_names[@]}" :::+ "${queue_xz_paths[@]}" :::+ "${queue_paths[@]}" >&2 2>/dev/null; then
    echo "All decompressions completed successfully." >&2
else
    echo "One or more decompressions failed." >&2
    exit 1
fi

# ==============================
# Partial Trim (If Local Mid-Chunk)
# ==============================
if [[ "${queue_starts[0]}" -ne "$update_start_num" ]]; then
    remote_name="${queue_names[0]}"
    remote_start="${queue_starts[0]}"
    remote_end="${queue_ends[0]}"
    remote_path="${queue_paths[0]}"

    echo "Trimming ${remote_name} to start from post ${update_start_num}..." >&2

    # Adjust metadata
    remote_suffix="_${remote_start}_${remote_end}"
    new_suffix="_${update_start_num}_${queue_ends[0]}"
    new_name="${remote_name%$remote_suffix}$new_suffix"
    new_start="$update_start_num"
    new_end="${remote_end}"
    new_path="$(mktemp "${local_dir}/$new_name.ndjson.tmp.XXXXXX")"
    queue_paths+=("$new_path")

    # Binary-search setup
    max_search_bytes=1048576
    buf_size=65536
    separator=$'\n'
    LC_ALL=C
    remote_size=$(stat -c%s "$remote_path")
    low=0
    high=$remote_size
    found_obj_start=-1
    found_obj_end=-1

    # Locate byte offset where post.num == update_start_num
    while [[ $low -le $high ]]; do
        mid=$(( (low + high) / 2 ))
        bytes_read=0
        line_start=-1
        line_end=-1
        read_pos=$mid

        # Search backward for start of line
        while (( read_pos > 0 && line_start == -1 )); do
            if (( read_pos < buf_size )); then
                read_start=0
            else
                read_start=$(( read_pos - buf_size ))
            fi
            to_read=$(( read_pos - read_start ))
            chunk="$(dd if="$remote_path" bs=64K iflag=skip_bytes,count_bytes skip=$read_start count=$to_read 2>/dev/null)"
            chunk_size=${#chunk}
            bytes_read=$(( bytes_read + chunk_size ))
            if (( bytes_read > max_search_bytes )); then
                echo "Error: Reached maximum search limit without finding line start." >&2
                exit 1
            fi
            remaining_chunk="${chunk%$separator*}"
            if [[ "$remaining_chunk" != "$chunk" ]]; then
                line_start=$(( read_start + ${#remaining_chunk} + 1 ))
                break
            fi
            read_pos=$read_start
        done
        (( line_start == -1 )) && line_start=0

        # Search forward for end of line
        read_pos=$mid
        while (( read_pos < remote_size && line_end == -1 )); do
            to_read_max=$(( remote_size - read_pos ))
            to_read=$buf_size
            (( to_read > to_read_max )) && to_read=$to_read_max

            chunk="$(dd if="$remote_path" bs=64K iflag=skip_bytes,count_bytes skip=$read_pos count=$to_read 2>/dev/null)"
            chunk_size=${#chunk}
            bytes_read=$(( bytes_read + chunk_size ))
            if (( bytes_read > max_search_bytes )); then
                echo "Error: Reached maximum search limit without finding line end." >&2
                exit 1
            fi
            remaining_chunk="${chunk#*$separator}"
            if [[ "$remaining_chunk" != "$chunk" ]]; then
                line_end=$(( read_pos + chunk_size - ${#remaining_chunk} - 1 ))
                break
            fi
            read_pos=$(( read_pos + buf_size ))
        done
        (( line_end == -1 )) && line_end=$remote_size

        if (( line_start >= line_end )); then
            echo "Error: Failed to determine line boundaries during binary search." >&2
            exit 1
        fi

        line_bytes=$(( line_end - line_start ))
        if (( line_bytes >= max_search_bytes )); then
            echo "Error: Line size exceeds maximum search limit." >&2
            exit 1
        fi
        line_json="$(dd if="$remote_path" bs="$line_bytes"B iflag=skip_bytes skip=$line_start count=1 2>/dev/null)"
        if ! line_num=$(jq -r '.num' <<<"$line_json" 2>/dev/null); then
            echo "Error: Failed to parse post JSON during binary search." >&2
            exit 1
        fi

        if (( line_num < update_start_num )); then
            # echo "[DEBUG] $line_num < $update_start_num" >&2
            low=$(( line_end + 1 ))
        elif (( line_num > update_start_num )); then
            # echo "[DEBUG] $line_num > $update_start_num" >&2
            high=$(( line_start - 1 ))
        else
            # echo "[DEBUG] $line_num == $update_start_num" >&2
            found_obj_start=$line_start
            found_obj_end=$line_end
            break
        fi
    done
    unset LC_ALL

    if (( found_obj_start == -1 || found_obj_end == -1 )); then
        echo "Error: Failed to locate post ${update_start_num} in remote file." >&2
        exit 1
    fi

    echo "Overwriting ${remote_name} to start from post ${update_start_num} at byte offset ${found_obj_start}..." >&2
    dd if="$remote_path" bs=16M iflag=skip_bytes skip=$found_obj_start of="$new_path" 2>/dev/null

    rm -f "$remote_path"
    unset 'queue_paths[-1]'
    queue_names[0]="$new_name"
    queue_starts[0]="$new_start"
    queue_ends[0]="$new_end"
    queue_paths[0]="$new_path"

    echo "Trim complete." >&2
fi

# ==============================
# Append Updates to Local Archive
# ==============================
for i in "${!queue_names[@]}"; do
    remote_name="${queue_names[i]}"
    remote_start="${queue_starts[i]}"
    remote_end="${queue_ends[i]}"
    remote_path="${queue_paths[i]}"
    echo "Appending posts ${remote_start}–${remote_end} from ${remote_name}..." >&2
    cat "$remote_path" >> "$local_file"
    rm -f "$remote_path"
done

echo "Updated posts from ${update_start_num} to ${update_end_num} appended to ${local_file}." >&2
