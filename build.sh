#!/bin/bash

# Build script for BullMQ KEDA External Scaler
# Supports Go and Python implementations

set -e

show_usage() {
  echo "Usage: $0 [implementation] [options]"
  echo ""
  echo "Implementations:"
  echo "  go       - Build Go implementation (default)"
  echo "  python   - Build Python implementation"
  echo ""
  echo "Options:"
  echo "  --tag TAG       - Docker image tag (default: latest)"
  echo "  --push          - Push image to registry after build"
  echo "  --load          - Load image into minikube after build"
  echo "  --no-cache      - Build without using Docker cache"
  echo "  --platform      - Target platform (e.g., linux/amd64,linux/arm64)"
  echo ""
  echo "Examples:"
  echo "  $0 go                           # Build Go implementation with latest tag"
  echo "  $0 python --tag v1.0.0         # Build Python implementation with v1.0.0 tag"
  echo "  $0 go --tag latest --load       # Build Go and load into minikube"
  echo "  $0 python --no-cache --push     # Build Python without cache and push"
  echo ""
}

# Default values
IMPLEMENTATION="go"
TAG="latest"
PUSH=false
LOAD=false
NO_CACHE=""
PLATFORM=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
  go | python)
    IMPLEMENTATION="$1"
    shift
    ;;
  --tag)
    TAG="$2"
    shift 2
    ;;
  --push)
    PUSH=true
    shift
    ;;
  --load)
    LOAD=true
    shift
    ;;
  --no-cache)
    NO_CACHE="--no-cache"
    shift
    ;;
  --platform)
    PLATFORM="--platform $2"
    shift 2
    ;;
  -h | --help)
    show_usage
    exit 0
    ;;
  *)
    echo "❌ Unknown option: $1"
    show_usage
    exit 1
    ;;
  esac
done

echo "🚀 Building BullMQ KEDA External Scaler"
echo "Implementation: $IMPLEMENTATION"
echo "Tag: $TAG"
echo "Push: $PUSH"
echo "Load into minikube: $LOAD"
echo ""

# Function to build Docker image
build_image() {
  local impl=$1
  local dockerfile_path=$2
  local context_path=$3
  local image_name="redis-bull-scaler:${TAG}"

  echo "🔨 Building $impl implementation..."
  echo "Dockerfile: $dockerfile_path"
  echo "Context: $context_path"
  echo "Image: $image_name"

  # Build the image
  docker build $NO_CACHE $PLATFORM \
    -f "$dockerfile_path" \
    -t "$image_name" \
    "$context_path"

  # Also tag as latest for local development if tag is not latest
  if [ "$TAG" != "latest" ]; then
    docker tag "$image_name" "redis-bull-scaler:latest"
  fi

  echo "✅ Successfully built $impl implementation as $image_name"

  # Push if requested
  if [ "$PUSH" = true ]; then
    echo "📤 Pushing $image_name..."
    docker push "$image_name"
    if [ "$TAG" != "latest" ]; then
      docker push "redis-bull-scaler:latest"
    fi
    echo "✅ Successfully pushed $image_name"
  fi

  # Load into minikube if requested
  if [ "$LOAD" = true ]; then
    echo "📥 Loading $image_name into minikube..."
    minikube image load "$image_name"
    if [ "$TAG" != "latest" ]; then
      minikube image load "redis-bull-scaler:latest"
    fi
    echo "✅ Successfully loaded $image_name into minikube"
  fi

  echo ""
}

# Check if Docker is available
if ! command -v docker &>/dev/null; then
  echo "❌ Docker is not installed or not in PATH"
  exit 1
fi

# Check if minikube is available when --load is specified
if [ "$LOAD" = true ] && ! command -v minikube &>/dev/null; then
  echo "❌ Minikube is not installed or not in PATH, but --load was specified"
  exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build based on implementation choice
case $IMPLEMENTATION in
go)
  build_image "go" "$SCRIPT_DIR/go/Dockerfile" "$SCRIPT_DIR/go"
  ;;
python)
  build_image "python" "$SCRIPT_DIR/python/Dockerfile" "$SCRIPT_DIR/python"
  ;;
*)
  echo "❌ Invalid implementation: $IMPLEMENTATION"
  show_usage
  exit 1
  ;;
esac

echo "🎉 Build completed successfully!"
echo ""
echo "📋 Built images:"
docker images | grep redis-bull-scaler | head -5

echo ""
echo "🚀 Next steps:"
echo "  1. Deploy the scaler: kubectl apply -f k8s/"
echo "  2. Test scaling: ./add-jobs.sh 5"
echo "  3. Monitor: kubectl get pods -w"
echo ""

if [ "$LOAD" = true ]; then
  echo "💡 Images loaded into minikube. You can now deploy to your cluster."
fi

if [ "$PUSH" = true ]; then
  echo "💡 Images pushed to registry. Update your manifests if needed."
fi
