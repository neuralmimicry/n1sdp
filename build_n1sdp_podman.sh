#!/usr/bin/env bash

# Title: Build the ARM N1SDP software stack using Podman
# Author: Paul B. Isaac's (NeuralMimicry)
# Date: 2025-01-14
# Version: 1.0
# Description:
# This script automates the building of the latest ARM N1SDP software stack,
# including the firmware and OS. It uses the last of the supported tags from
# the ARM Reference Solutions repository and builds the software stack by
# syncing the repository and running the build scripts. The script also nudges
# some of the version numbers of the component parts forward as best as possible.

#set -euo pipefail

# Constants
REPO_URL="https://git.gitlab.arm.com/arm-reference-solutions/arm-reference-solutions-manifest.git"
DOCKERFILE="Dockerfile"
DOCKERFILE_REPO="https://git.gitlab.arm.com/arm-reference-solutions/docker.git"
DOCKERFILE_BRANCH="N1SDP-2024.06.14"
#DOCKERFILE_BRANCH="N1SDP-2023.06.22"
CONTAINER_NAME="n1sdp-builder"
WORKSPACE_DIR="$(pwd)/n1sdp_workspace"
N1SDP_RELEASE="refs/tags/N1SDP-2024.06.14"
#N1SDP_RELEASE="refs/tags/N1SDP-2022.06.22"
BUILD_TARGET="ubuntu" # Change to "ubuntu", "bsp", "none" or "busybox" if needed
MODIFIED_MANIFEST="pinned-n1sdp-updated.xml"

# Create the workspace directory
mkdir -p "$WORKSPACE_DIR"
chmod 777 "$WORKSPACE_DIR"

# Ensure .repo directory exists
mkdir -p "$WORKSPACE_DIR/.repo"
chmod 777 "$WORKSPACE_DIR/.repo"

# Function to ensure Podman is available
check_dependencies() {
    if ! command -v podman &>/dev/null; then
        echo "[ERROR] Podman is not installed. Please install Podman and try again."
        exit 1
    fi

    if ! command -v git &>/dev/null; then
        echo "[ERROR] Git is not installed. Please install Git and try again."
        exit 1
    fi
}

# Clone and build the Podman container
clone_container() {
    echo "[INFO] Cloning Dockerfile repository..."
    git clone -b "$DOCKERFILE_BRANCH" "$DOCKERFILE_REPO" docker/
}

# Build the Podman container
build_container() {
    echo "[INFO] Building Podman container..."
    buildah bud --build-arg GIT_USER="masterkiga" --build-arg GIT_EMAIL="paul@neuralmimicry.ai" -t "$CONTAINER_NAME:latest" ./docker/
}

# Create an alias for Podman run
setup_podman_alias() {
    echo "[INFO] Setting up Podman alias..."
    podman_run() {
        podman run --rm \
            --runtime runc \
            --volume "$WORKSPACE_DIR:/workspace" \
            --env TERM="$TERM" \
            --user "$(id -u):$(id -g)" \
            -it "$CONTAINER_NAME" "$@"
    }
}

amend_dockerfile() {
  # Script to automatically update the Dockerfile to add Poetry installation
cd docker || echo "Error: docker directory not found."
#cp ../*.SCP280 ./
#rm .dockerignore
# Check if Dockerfile exists
if [ ! -f "$DOCKERFILE" ]; then
    echo "Error: $DOCKERFILE not found in the current directory."
    exit 1
fi

# Check if Poetry is already installed in the Dockerfile
if grep -q "Install Poetry" "$DOCKERFILE"; then
    echo "Poetry installation steps are already present in $DOCKERFILE."
    exit 0
fi

# Backup the original Dockerfile
cp "$DOCKERFILE" "${DOCKERFILE}.bak"
echo "Backup of Dockerfile created at ${DOCKERFILE}.bak"

# Define the Poetry installation commands
read -r -d '' POETRY_INSTALL << EOM
    # Install Poetry
    RUN curl -sSL https://install.python-poetry.org | python3 - && \\
        ln -s /root/.local/bin/poetry /usr/local/bin/poetry

    # Verify Poetry installation
    RUN poetry --version
EOM


# Now, substitute 'dummy-user' and 'invalid-email' with variables GIT_USER and GIT_EMAIL

# Check if ARG declarations for GIT_USER and GIT_EMAIL already exist
if grep -q "ARG GIT_USER" "$DOCKERFILE" && grep -q "ARG GIT_EMAIL" "$DOCKERFILE"; then
    echo "ARG GIT_USER and ARG GIT_EMAIL are already present in $DOCKERFILE."
else
    # Backup again before making changes
    cp "$DOCKERFILE" "${DOCKERFILE}.bak2"
    echo "Backup of Dockerfile before Git config changes created at ${DOCKERFILE}.bak2"

    # Insert ARG declarations before the git config RUN command
    # Find the line number containing 'git config --global user.name "dummy-user"'
    GIT_CONFIG_LINE=$(grep -n 'git config --global user.name "dummy-user"' "$DOCKERFILE" | head -n1 | cut -d: -f1)

    if [ -z "$GIT_CONFIG_LINE" ]; then
        echo "Error: Could not find 'git config --global user.name \"dummy-user\"' in $DOCKERFILE."
        exit 1
    fi

    # Insert ARG GIT_USER and ARG GIT_EMAIL before GIT_CONFIG_LINE
    sed -i "${GIT_CONFIG_LINE}i \\
    ARG GIT_USER=${GIT_USER}\\
    ARG GIT_EMAIL=${GIT_EMAIL}" "$DOCKERFILE"

    echo "Added ARG GIT_USER and ARG GIT_EMAIL before Git configuration."

    # Now, replace "dummy-user" with "\$GIT_USER" and "invalid-email" with "\$GIT_EMAIL"
    # Using sed to perform the replacements
    sed -i "s/git config --global user.name \"dummy-user\"/git config --global user.name \"\${GIT_USER}\"/" "$DOCKERFILE"
    sed -i "s/git config --global user.email \"invalid-email\"/git config --global user.email \"\${GIT_EMAIL}\"/" "$DOCKERFILE"

    echo "Replaced 'dummy-user' with '\$GIT_USER' and 'invalid-email' with '\$GIT_EMAIL' in Git configuration."
fi

# Insert the Poetry installation steps after the RUN apt-get install line
# Find the line number containing 'apt-get install -y'
INSTALL_LINE=$(grep -n "zstd" "$DOCKERFILE" | head -n1 | cut -d: -f1)

if [ -z "$INSTALL_LINE" ]; then
    INSTALL_LINE=$(grep -n "wget" "$DOCKERFILE" | head -n1 | cut -d: -f1)
fi

if [ -z "$INSTALL_LINE" ]; then
    echo "Error: Could not find 'apt-get install -y' in $DOCKERFILE."
    exit 1
fi

# Use sed to insert the Poetry installation steps after the INSTALL_LINE
sed -i "${INSTALL_LINE}a \\
    \\
    RUN git config --global credential.helper store && \\\\ \\
        echo 'https://<YOUR_GITHUB_PAT>@github.com' > \$HOME/.git-credentials && \\\\ \\
        echo 'https://<YOUR_ARM_GITLAB_PAT>@gitlab.arm.com' >> \$HOME/.git-credentials && \\\\ \\
        chmod 600 \$HOME/.git-credentials && \\\\ \\
        git config --global url.'https://github.com/tianocore/'.insteadOf 'https://github.com/Zeex/' \\
    \\
    RUN apt-get install -y curl gawk acpica-tools ninja-build doxygen libpixman-1-dev gcc-arm-none-eabi python3-pip python-is-python3 \\
    # Set up global Poetry installation \\
    ENV POETRY_HOME="/usr/local/poetry" \\
    ENV PATH="/usr/local/poetry/bin:${PATH}" \\
    \\
    # Install Poetry globally \\
    # RUN curl -sSL https://install.python-poetry.org | POETRY_HOME="/usr/local/poetry" python3 - \\
    # RUN chmod -R a+rX /usr/local/poetry \\
    # RUN ln -s /usr/local/poetry/bin/poetry /usr/local/bin/poetry \\
    RUN python3 -m pip install poetry \\
    \\
    # Verify Poetry installation \\
    RUN poetry --version" "$DOCKERFILE"


# Optionally, you can print the modified Dockerfile or specific lines for verification
echo "Modified Dockerfile:"
cat "$DOCKERFILE"
cd ..
}

# Sync and build the firmware/OS
build_n1sdp() {
    echo "[INFO] Initialising repo with modified manifest..."

    # Intentionally init with a dummy manifest to avoid syncing the entire repository
    podman_run repo init \
        -u "$REPO_URL" \
        -b "$N1SDP_RELEASE" \
        -g "$BUILD_TARGET" \
        -m "no-manifest.xml" || true

    podman_run git config --global --add safe.directory /workspace/.repo/manifests

    echo "Checking username and group:"
    podman_run id -un

    echo "[INFO] Ensuring write permissions for the .repo directory..."

    echo "[INFO] Copying and fixing the manifest file..."
    # Copy the pinned manifest
    podman_run cp "/workspace/.repo/manifests/pinned-n1sdp.xml" "/workspace/.repo/manifests/$MODIFIED_MANIFEST"

    echo "[INFO] Initialising repo with unmodified manifest..."
    podman_run repo init \
        -u "$REPO_URL" \
        -b "$N1SDP_RELEASE" \
        -g "$BUILD_TARGET" \
        -m "$MODIFIED_MANIFEST"

    # Update the manifest with the correct repository URL
    echo "[INFO] Updating repository URLs in all files..."

    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|edk2-stable202405|edk2-stable202411|g' {} +
    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|remote="github" revision="de7e464ecd77130147103cf48328099c2d0e6289" upstream="master"|remote="gitlab" revision="refs/tags/v2.15.0"|g' {} +
    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|name="ARM-software/SCP-firmware|name="firmware/SCP-firmware|g' {} +
    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|35bca3ca71c004b7f3d93c6f33724796c6b1bf0b|refs/heads/master|g' {} +
    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|refs/tags/v3.6.0|refs/tags/v3.6.2|g' {} +
    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|refs/tags/v2.11.0|refs/tags/v2.12.0|g' {} +
    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|refs/tags/v2.14.0|refs/tags/v2.15.0|g' {} +
    find "$WORKSPACE_DIR/.repo" -type f -exec sudo sed -i 's|refs/tags/grub-2.06|refs/tags/grub-2.12|g' {} +

    echo "Modified manifest:"
    podman_run cat "/workspace/.repo/manifests/$MODIFIED_MANIFEST"

    echo "[INFO] Syncing the repository..."
    podman_run repo sync
    echo "Checking permissions for $WORKSPACE_DIR:"
    podman_run ls -ld "/workspace"
    podman_run ls -l "/workspace/.repo/manifests"

    echo "[INFO] Building N1SDP software stack..."
    podman_run ./build-scripts/check_dep.sh
    podman_run ./build-scripts/fetch-tools.sh -f none
    podman_run ./build-scripts/build-all.sh -f "$BUILD_TARGET"
}

# Main script execution
main() {
    check_dependencies
    clone_container
    amend_dockerfile
    build_container
    setup_podman_alias
    build_n1sdp

    echo "[INFO] Build complete."
    echo "[INFO] Output available in $WORKSPACE_DIR/output/n1sdp/"
}

main "$@"
