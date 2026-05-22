#!/bin/bash
set -e

# Configuration
IMAGE_NAME="ghcr.io/lbnl-science-it/lightrag"
DOCKERFILE="Dockerfile"
TAG="latest"
PLATFORM="linux/amd64"

# Get version from git tags
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")

echo "=================================="
echo "  Podman Build & Push (amd64)"
echo "=================================="
echo "Image: ${IMAGE_NAME}:${TAG}"
echo "Version: ${VERSION}"
echo "Platform: ${PLATFORM}"
echo "=================================="
echo ""

# Check registry login status (skip if CR_PAT is set for CI/CD)
if [ -z "$CR_PAT" ]; then
    if ! podman login --get-login ghcr.io &>/dev/null; then
        echo "Warning: Not logged in to ghcr.io"
        echo "Please login first: podman login ghcr.io"
        echo "Or set CR_PAT environment variable for automated login"
        echo ""
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
else
    echo "Logging in with CR_PAT..."
    echo "${CR_PAT}" | podman login ghcr.io --username "${CR_PAT_USER:-github}" --password-stdin
fi

echo ""
echo "Building image for ${PLATFORM}..."
echo ""

# Build for amd64 -- tag with both :latest and :version
podman build \
  --platform "${PLATFORM}" \
  --file "${DOCKERFILE}" \
  --tag "${IMAGE_NAME}:${TAG}" \
  --tag "${IMAGE_NAME}:${VERSION}" \
  .

echo ""
echo "Pushing images..."
echo ""

podman push "${IMAGE_NAME}:${TAG}"
podman push "${IMAGE_NAME}:${VERSION}"

echo ""
echo "Build and push complete!"
echo ""
echo "Images pushed:"
echo "  - ${IMAGE_NAME}:${TAG}"
echo "  - ${IMAGE_NAME}:${VERSION}"
echo ""
echo "Verifying image..."
echo ""

# Verify the local image -- single-arch images are not manifest lists,
# so use podman image inspect rather than manifest inspect.
podman image inspect "${IMAGE_NAME}:${TAG}" \
  --format 'Architecture: {{.Architecture}}\nOS: {{.Os}}\nDigest: {{.Digest}}'

echo ""
echo "Verification complete!"
echo ""
echo "Pull with: podman pull ${IMAGE_NAME}:${TAG}"
