#!/bin/bash

# ==============================================================================
# Install Script for Worktree Utils
# Downloads the suite of scripts into ./scripts/ and creates a default config.
# Usage: curl -fsSL https://raw.githubusercontent.com/vladislavlozhkin/worktree-utils/main/install.sh | bash
# ==============================================================================

set -e

REPO_BASE_URL="https://raw.githubusercontent.com/vladislavlozhkin/worktree-utils/main"
TARGET_DIR="scripts"

echo "🚀 Installing worktree-utils..."

# 1. Create the scripts directory
if [ ! -d "$TARGET_DIR" ]; then
    echo "Creating directory: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

# 2. Define the list of scripts to download
SCRIPTS=("wt" "wt-new" "wt-setup" "wt-list" "wt-kill" "wt-task")

# 3. Download each script
for script in "${SCRIPTS[@]}"; do
    url="${REPO_BASE_URL}/scripts/${script}"
    dest="${TARGET_DIR}/${script}"
    
    echo "⬇️  Downloading $script..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        echo "❌ Error: Neither curl nor wget found. Please install one of them."
        exit 1
    fi
    
    chmod +x "$dest"
done

# 4. Download default configuration if it doesn't exist
CONFIG_FILE=".worktree-config"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "⬇️  Downloading default configuration to $CONFIG_FILE..."
    url="${REPO_BASE_URL}/.worktree-config"
    
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$CONFIG_FILE"
    else
        wget -qO "$CONFIG_FILE" "$url"
    fi
else
    echo "ℹ️  $CONFIG_FILE already exists, skipping download."
fi

echo ""
echo "✅ Installation complete!"
echo ""
echo "You can now use the tools:"
echo "  ./scripts/wt help"
echo ""
echo "Recommended: Add ./scripts to your .gitignore if you don't want to track them,"
echo "or commit them if you want to share them with your team."
