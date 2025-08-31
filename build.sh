#!/bin/bash

# Build script for P2P Network Docker image

set -e

# Configuration
IMAGE_NAME="p2p-network"
TAG=${1:-"latest"}
FULL_IMAGE_NAME="${IMAGE_NAME}:${TAG}"

echo "Building P2P Network Docker image..."
echo "Image: ${FULL_IMAGE_NAME}"

# Build the Docker image
docker build -t "${FULL_IMAGE_NAME}" .

echo "Build completed successfully!"
echo "Image: ${FULL_IMAGE_NAME}"

# Show image info
docker images | grep "${IMAGE_NAME}" | head -1

echo ""
echo "To run the image locally:"
echo "docker run -p 4001:4001 ${FULL_IMAGE_NAME}"
echo ""
echo "To push to a registry:"
echo "docker tag ${FULL_IMAGE_NAME} your-registry.com/${FULL_IMAGE_NAME}"
echo "docker push your-registry.com/${FULL_IMAGE_NAME}"
