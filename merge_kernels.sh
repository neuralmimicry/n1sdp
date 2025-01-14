#!/bin/bash

# Title: Merge and optionally build two Linux kernel versions
# Author: Paul B. Isaac's (NeuralMimicry)
# Date: 2025-01-14
# Version: 1.0
# Description:
# Merge two kernel versions using git and optionally build the kernel.
# This script checks if you are on an ARM64 system (aarch64). If yes,
# it can build natively using an existing kernel config if present.
# Otherwise, it checks if the cross-compiler is installed and, if not,
# installs it (Debian/Ubuntu example) and offers cross-compilation.
# This script helps keep the ARM N1SDP kernel up-to-date so that you
# can test new features or fixes on your hardware, including NVIDIA GPUs.

set -e  # Exit immediately on error

UPSTREAM_REMOTE="linux-stable"
UPSTREAM_URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
UPSTREAM_REF="v6.8.11"          # Could also be linux-stable/linux-6.8.y if you prefer a branch
MERGED_BRANCH="v6.8.11-n1sdp"

CUSTOM_REMOTE="custom-kernel"
CUSTOM_URL="https://git.gitlab.arm.com/arm-reference-solutions/linux.git"
CUSTOM_REF="N1SDP-2024.06.14"
TEMP_BRANCH="arm-n1sdp-temp"
git config --global user.email "paul@neuralmimicry.ai"
git config --global user.name "masterkiga"

echo "-----------------------------------------------------------"
echo "1. Setting up or reusing kernel merge workspace"
echo "-----------------------------------------------------------"

mkdir -p merged-kernel
cd merged-kernel || exit

# 1. (Re)initialize only if there's no existing .git folder
if [ ! -d .git ]; then
  echo "No .git directory found. Initializing repository..."
  git init -b main
else
  echo "Git repository already exists. Skipping init."
fi

echo "-----------------------------------------------------------"
echo "2. Adding and fetching upstream kernel: $UPSTREAM_REF"
echo "-----------------------------------------------------------"

# 2. Add upstream kernel remote if it does not exist
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
else
  echo "Remote '$UPSTREAM_REMOTE' already exists. Skipping remote add."
fi

# Always fetch to make sure we have the latest references
git fetch --all --tags

# 2a. Create or reset the merged branch to the upstream reference
if git rev-parse --verify "$MERGED_BRANCH" >/dev/null 2>&1; then
  echo "Branch '$MERGED_BRANCH' already exists. Resetting it to $UPSTREAM_REF..."
  git checkout "$MERGED_BRANCH"
  git reset --hard "$UPSTREAM_REF"
else
  echo "Creating new branch '$MERGED_BRANCH' from $UPSTREAM_REF..."
  git checkout -b "$MERGED_BRANCH" "$UPSTREAM_REF"
fi

echo "-----------------------------------------------------------"
echo "3. Adding custom changes from ARM N1SDP branch"
echo "-----------------------------------------------------------"

# 3. Add custom remote if needed
if ! git remote get-url "$CUSTOM_REMOTE" >/dev/null 2>&1; then
  git remote add "$CUSTOM_REMOTE" "$CUSTOM_URL"
else
  echo "Remote '$CUSTOM_REMOTE' already exists. Skipping remote add."
fi

# Fetch the custom branch/tags in case there are updates
git fetch "$CUSTOM_REMOTE"

# Delete temp branch if it exists
if git rev-parse --verify "$TEMP_BRANCH" >/dev/null 2>&1; then
  echo "Branch '$TEMP_BRANCH' already exists. Deleting..."
  git branch -D "$TEMP_BRANCH"
fi

# Recreate temp branch from custom ref
echo "Creating new branch '$TEMP_BRANCH' from $CUSTOM_REF..."
git checkout -b "$TEMP_BRANCH" "$CUSTOM_REMOTE/$CUSTOM_REF"

echo "-----------------------------------------------------------"
echo "4. Cherry-picking commits from the N1SDP branch into '$MERGED_BRANCH'"
echo "-----------------------------------------------------------"

# Switch back to the merged branch
git checkout "$MERGED_BRANCH"

# Show relevant commits in the custom ref
echo "Searching for commits mentioning n1sdp, N1SDP, pci_quirk, pcie, or quirk:"
git --no-pager log -P --grep='\b(n1sdp|N1SDP|pci_quirk|pcie|quirk)\b' --oneline "$CUSTOM_REMOTE/$CUSTOM_REF"

# Example cherry-pick of relevant commits
echo "Cherry-picking commits..."
git cherry-pick --no-edit 91443f8d1b15 6baab5182aea f6dedbb6372a 020a0679d0da a7b28cbe547f
git cherry-pick --continue

# If conflicts occur, you'd fix them, then:
git add .
git commit -m "Merge N1SDP commits into $MERGED_BRANCH"

echo "-----------------------------------------------------------"
echo "Merge complete. Now, let's decide how to compile the kernel."
echo "-----------------------------------------------------------"

# 5. Determine host architecture
ARCH_DETECTED=$(uname -m)

if [ "$ARCH_DETECTED" = "aarch64" ]; then
    # On ARM64 system
    read -rp "Detected ARM64 (aarch64). Build natively? (y/n): " build_native
    if [[ "$build_native" =~ ^[Yy]$ ]]; then
        echo "Building natively on ARM64..."

        # Check if there's an existing config in /boot
        NATIVE_CONFIG_PATH="/boot/config-$(uname -r)"
        if [ -f "$NATIVE_CONFIG_PATH" ]; then
            echo "Found existing kernel config at $NATIVE_CONFIG_PATH"
            echo "Copying it to .config and running olddefconfig..."
            cp "$NATIVE_CONFIG_PATH" .config
            make olddefconfig
        else
            echo "No existing kernel config found in /boot. Running menuconfig..."
            make menuconfig
        fi

        echo "Starting kernel build..."
        make -j"$(nproc)"
        # Uncomment if you want to install modules and kernel automatically
        # sudo make modules_install
        # sudo make install
    else
        echo "Skipping build or cross-compiling manually later."
    fi
else
    # On a non-ARM system
    # Check if cross-compiler is installed
    if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        echo "No aarch64-linux-gnu-gcc found. Attempting to install..."
        # Example for Debian/Ubuntu:
        sudo apt-get update
        sudo apt-get install -y gcc-aarch64-linux-gnu
    fi

    # Verify again after attempted install
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        read -rp "Detected non-ARM system. Use cross-compile? (y/n): " build_cross
        if [[ "$build_cross" =~ ^[Yy]$ ]]; then
            echo "Building via cross-compiler..."
            make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
            make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
            # Uncomment if you want to install modules and kernel automatically
            # sudo make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install
            # sudo make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- install
        else
            echo "Skipping build. You can manually compile later as needed."
        fi
    else
        echo "Failed to install cross-compiler or no supported method found."
        echo "Cannot cross-compile at this time."
    fi
fi

echo "-----------------------------------------------------------"
echo "Script completed."
echo "-----------------------------------------------------------"
