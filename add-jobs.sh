#!/bin/bash

# Script to add test jobs to Redis Bull queue for testing KEDA scaling

set -e

show_usage() {
  echo "Usage: $0 [number_of_jobs]"
  echo ""
  echo "Required environment variables:"
  echo "  REDIS_HOST    - Redis server hostname"
  echo "  REDIS_PORT    - Redis server port"
  echo "  WAIT_QUEUE    - Redis list name for waiting jobs"
  echo "  ACTIVE_QUEUE  - Redis list name for active jobs"
  echo ""
  echo "Example:"
  echo "  export REDIS_HOST=localhost"
  echo "  export REDIS_PORT=6379"
  echo "  export WAIT_QUEUE=bull:test-queue:wait"
  echo "  export ACTIVE_QUEUE=bull:test-queue:active"
  echo "  $0 5"
  echo ""
}

# Check for help flag
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  show_usage
  exit 0
fi

# Configuration - fail fast if required env vars not set
if [ -z "$REDIS_HOST" ]; then
  echo "❌ Error: REDIS_HOST environment variable is required"
  show_usage
  exit 1
fi

if [ -z "$REDIS_PORT" ]; then
  echo "❌ Error: REDIS_PORT environment variable is required"
  show_usage
  exit 1
fi

if [ -z "$WAIT_QUEUE" ]; then
  echo "❌ Error: WAIT_QUEUE environment variable is required"
  show_usage
  exit 1
fi

if [ -z "$ACTIVE_QUEUE" ]; then
  echo "❌ Error: ACTIVE_QUEUE environment variable is required"
  show_usage
  exit 1
fi

# Default number of jobs to add
NUM_JOBS=${1:-5}

echo "Adding $NUM_JOBS jobs to Redis queue..."
echo "Redis: $REDIS_HOST:$REDIS_PORT"
echo "Wait Queue: $WAIT_QUEUE"

# Check if redis-cli is available
if ! command -v redis-cli &>/dev/null; then
  echo "Error: redis-cli is not installed. Please install Redis CLI tools."
  exit 1
fi

# Test Redis connection
if ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
  echo "Error: Cannot connect to Redis at $REDIS_HOST:$REDIS_PORT"
  exit 1
fi

echo "Connected to Redis successfully!"

# Add jobs to the queue
for i in $(seq 1 $NUM_JOBS); do
  JOB_DATA="{\"id\":$i,\"data\":\"test-job-$i\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LPUSH "$WAIT_QUEUE" "$JOB_DATA" >/dev/null
  echo "Added job $i: $JOB_DATA"
done

echo ""
echo "✅ Successfully added $NUM_JOBS jobs to the queue!"

# Show current queue status
WAIT_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN "$WAIT_QUEUE")
ACTIVE_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN "$ACTIVE_QUEUE")

echo ""
echo "📊 Queue Status:"
echo "  Wait Queue ($WAIT_QUEUE): $WAIT_COUNT jobs"
echo "  Active Queue ($ACTIVE_QUEUE): $ACTIVE_COUNT jobs"
echo "  Total: $((WAIT_COUNT + ACTIVE_COUNT)) jobs"

echo ""
echo "🚀 KEDA should now scale up the workers based on queue length!"
echo ""
echo "To monitor scaling:"
echo "  kubectl get pods -n bullmq-test -w"
echo ""
echo "To check queue status:"
echo "  redis-cli -h $REDIS_HOST -p $REDIS_PORT LLEN $WAIT_QUEUE"
echo "  redis-cli -h $REDIS_HOST -p $REDIS_PORT LLEN $ACTIVE_QUEUE"
