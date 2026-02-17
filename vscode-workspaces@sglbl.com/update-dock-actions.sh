#!/bin/bash
# update-dock-actions.sh
# Dynamically updates the VS Code .desktop file with recent workspace actions
# so they appear in the right-click menu on Zorin Dash / Dash-to-Dock.
#
# Usage: ./update-dock-actions.sh [--max N] [--editor code|cursor|codium|auto]
# Defaults: max=10, editor=auto (picks whichever has the most recent activity)

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
MAX_ITEMS=10
EDITOR_CHOICE="auto"
CONFIG_DIR="$HOME/.config"
DESKTOP_TARGET="$HOME/.local/share/applications/code.desktop"
SYSTEM_DESKTOP="/usr/share/applications/code.desktop"

# ── Parse Arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max)    MAX_ITEMS="$2"; shift 2 ;;
        --editor) EDITOR_CHOICE="$2"; shift 2 ;;
        *)        echo "Unknown option: $1"; exit 1 ;;
    esac
done

# If choice is still auto, try to read from extension settings
if [[ "$EDITOR_CHOICE" == "auto" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$SCRIPT_DIR/schemas" ]]; then
        # Try to read the extension setting for editor-location
        SAVED_SETTING=$(GSETTINGS_SCHEMA_DIR="$SCRIPT_DIR/schemas" gsettings get org.gnome.shell.extensions.vscode-workspaces editor-location 2>/dev/null || true)
        
        # Remove single quotes from the output (e.g., 'code' -> code)
        SAVED_SETTING="${SAVED_SETTING%\'}"
        SAVED_SETTING="${SAVED_SETTING#\'}"
        
        if [[ -n "$SAVED_SETTING" && "$SAVED_SETTING" != "auto" ]]; then
            EDITOR_CHOICE="$SAVED_SETTING"
        fi
    fi
fi

# ── Editor Definitions ────────────────────────────────────────────────────────
# Each entry: name|binary|workspaceStoragePath
declare -a EDITORS=(
    "vscode|code|$CONFIG_DIR/Code/User/workspaceStorage"
    "cursor|cursor|$CONFIG_DIR/Cursor/User/workspaceStorage"
    "antigravity|antigravity|$CONFIG_DIR/Antigravity/User/workspaceStorage"
    "codium|codium|$CONFIG_DIR/VSCodium/User/workspaceStorage"
    "code-insiders|code-insiders|$CONFIG_DIR/Code - Insiders/User/workspaceStorage"
)

# ── Resolve Editor ────────────────────────────────────────────────────────────
EDITOR_BINARY=""
WORKSPACE_DIR=""

resolve_editor() {
    local choice="$1"

    if [[ "$choice" == "auto" ]]; then
        # Pick the editor whose workspaceStorage has the most recently modified file
        local best_mtime=0
        for entry in "${EDITORS[@]}"; do
            IFS='|' read -r name binary wspath <<< "$entry"
            if [[ -d "$wspath" ]]; then
                # Find the most recently modified workspace.json
                local latest
                latest=$(find "$wspath" -name "workspace.json" -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
                if [[ -n "$latest" ]]; then
                    local mtime_int=${latest%%.*}
                    if (( mtime_int > best_mtime )); then
                        best_mtime=$mtime_int
                        EDITOR_BINARY="$binary"
                        WORKSPACE_DIR="$wspath"
                    fi
                fi
            fi
        done
    else
        for entry in "${EDITORS[@]}"; do
            IFS='|' read -r name binary wspath <<< "$entry"
            if [[ "$binary" == "$choice" || "$name" == "$choice" ]]; then
                EDITOR_BINARY="$binary"
                WORKSPACE_DIR="$wspath"
                break
            fi
        done
    fi

    if [[ -z "$EDITOR_BINARY" || -z "$WORKSPACE_DIR" || ! -d "$WORKSPACE_DIR" ]]; then
        echo "Error: Could not find editor workspace storage." >&2
        echo "  Editor choice: $choice" >&2
        echo "  Resolved binary: ${EDITOR_BINARY:-none}" >&2
        echo "  Workspace dir: ${WORKSPACE_DIR:-none}" >&2
        exit 1
    fi
}

resolve_editor "$EDITOR_CHOICE"

# ── Collect Recent Workspaces ─────────────────────────────────────────────────

# Try to read favorites from extension settings
FAVORITES=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_DIR/schemas" ]]; then
    # gsettings get returns something like "['uri1', 'uri2']"
    FAV_RAW=$(GSETTINGS_SCHEMA_DIR="$SCRIPT_DIR/schemas" gsettings get org.gnome.shell.extensions.vscode-workspaces favorite-workspaces 2>/dev/null || echo "[]")
    # Convert to simple space-separated list for easy grepping
    FAVORITES=$(echo "$FAV_RAW" | tr -d "[]'," )
fi

# Output: is_favorite|mtime|uri|folder_path
collect_workspaces() {
    local ws_dir="$1"

    # Optimization: processing thousands of JSONs is slow.
    # Logic matched with core.js: sort directories by activity first.
    while read -r ts dir_path; do
        local ws_json="$dir_path/workspace.json"
        [[ -f "$ws_json" ]] || continue

        local uri
        uri=$(python3 -c "
import json, sys
try:
    d = json.load(open('$ws_json'))
    print(d.get('folder', d.get('workspace', '')))
except:
    pass
" 2>/dev/null)

        [[ -z "$uri" ]] && continue
        [[ "$uri" == vscode-remote://* || "$uri" == docker://* ]] && continue

        local decoded_path
        decoded_path=$(python3 -c "
import urllib.parse, sys
uri = '$uri'
if uri.startswith('file://'):
    print(urllib.parse.unquote(uri[7:]))
else:
    print(uri)
" 2>/dev/null)

        if [[ -n "$decoded_path" && -e "$decoded_path" ]]; then
            local is_fav=0
            # Check if this URI is in our favorites list
            if [[ " $FAVORITES " == *" $uri "* ]]; then
                is_fav=1
            fi
            
            # Key: is_fav | mtime (without decimal)
            echo "${is_fav}|${ts%%.*}|${uri}|${decoded_path}"
        fi
    done < <(find "$ws_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 50)
}

# Collect and sort: 
# 1. Sort by is_fav (field 1) DESC
# 2. Sort by mtime (field 2) DESC
# 3. Deduplicate by URI (field 3)
# 4. Take top N
WORKSPACES=$(collect_workspaces "$WORKSPACE_DIR" | sort -t'|' -k1,1rn -k2,2rn | awk -F'|' '!seen[$3]++' | head -n "$MAX_ITEMS")

if [[ -z "$WORKSPACES" ]]; then
    echo "No recent workspaces found. Desktop file not updated."
    exit 0
fi

# ── Build .desktop File ──────────────────────────────────────────────────────

# Start with the base desktop entry from the system file
if [[ -f "$SYSTEM_DESKTOP" ]]; then
    BASE_DESKTOP=$(cat "$SYSTEM_DESKTOP")
else
    echo "Error: System desktop file not found at $SYSTEM_DESKTOP" >&2
    exit 1
fi

# Extract just the [Desktop Entry] section (before any [Desktop Action ...])
HEADER=$(echo "$BASE_DESKTOP" | awk '/^\[Desktop Action/{exit} {print}')

# (Adjusting the read loop to handle the extra field: is_fav|mtime|uri|path)
INDEX=0
ACTION_IDS=()
ACTION_SECTIONS=""

while IFS='|' read -r is_fav mtime uri decoded_path; do
    # Get a display name (basename of the path)
    local_name=$(basename "$decoded_path")
    # Strip .code-workspace extension for display
    local_name="${local_name%.code-workspace}"

    # Make a clean action ID
    action_id="workspace-${INDEX}"
    ACTION_IDS+=("$action_id")

    # Build the action section
    ACTION_SECTIONS+="
[Desktop Action ${action_id}]
Name=${local_name}
Exec=${EDITOR_BINARY} \"${decoded_path}\"
Icon=vscode
"
    INDEX=$((INDEX + 1))
done <<< "$WORKSPACES"

# Build the Actions= line by joining all action IDs with ;
# Start with the original action (new-empty-window) then add workspace actions
ALL_ACTIONS="new-empty-window"
for aid in "${ACTION_IDS[@]}"; do
    ALL_ACTIONS="${ALL_ACTIONS};${aid}"
done

# Replace or add the Actions= line in the header
if echo "$HEADER" | grep -q '^Actions='; then
    HEADER=$(echo "$HEADER" | sed "s/^Actions=.*/Actions=${ALL_ACTIONS};/")
else
    HEADER+=$'\n'"Actions=${ALL_ACTIONS};"
fi

# Assemble the final desktop file
FINAL_CONTENT="${HEADER}

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=${EDITOR_BINARY} --new-window %F
Icon=vscode
${ACTION_SECTIONS}"

# ── Write Output ──────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$DESKTOP_TARGET")"
echo "$FINAL_CONTENT" > "$DESKTOP_TARGET"

echo "✓ Updated $DESKTOP_TARGET with ${#ACTION_IDS[@]} recent workspaces (editor: $EDITOR_BINARY)"
echo "  Workspaces:"
while IFS='|' read -r mtime uri decoded_path; do
    echo "    • $(basename "$decoded_path")"
done <<< "$WORKSPACES"

# Force GNOME Shell / Desktop Entry system to refresh the cache
update-desktop-database "$(dirname "$DESKTOP_TARGET")" >/dev/null 2>&1 || true
