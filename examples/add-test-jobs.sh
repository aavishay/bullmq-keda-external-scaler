#!/bin/bash

# Script to add test jobs to multiple Redis Bull queues for testing KEDA scaling
# This script demonstrates the multi-queue capabilities of the external scaler

set -e

show_usage() {
  echo "Usage: $0 [scenario] [number_of_jobs_per_queue]"
  echo ""
  echo "Scenarios:"
  echo "  high-priority    - Add jobs only to high priority queue"
  echo "  standard         - Add jobs only to standard priority queue"
  echo "  low-priority     - Add jobs only to low priority queue"
  echo "  batch            - Add jobs only to batch processing queue"
  echo "  mixed            - Add jobs to all queues (default)"
  echo "  burst            - Add many jobs quickly to test scaling"
  echo ""
  echo "Required environment variables:"
  echo "  REDIS_HOST    - Redis server hostname"
  echo "  REDIS_PORT    - Redis server port"
  echo ""
  echo "Examples:"
  echo "  export REDIS_HOST=localhost"
  echo "  export REDIS_PORT=6379"
  echo "  $0 mixed 5          # Add 5 jobs to each queue"
  echo "  $0 high-priority 10 # Add 10 jobs to high priority queue only"
  echo "  $0 burst 50         # Add 50 jobs to each queue for load testing"
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

# Parse arguments
SCENARIO=${1:-mixed}
NUM_JOBS=${2:-5}

# Validate scenario
case $SCENARIO in
high-priority | standard | low-priority | batch | mixed | burst) ;;
*)
  echo "❌ Error: Invalid scenario '$SCENARIO'"
  show_usage
  exit 1
  ;;
esac

# Validate number of jobs
if ! [[ "$NUM_JOBS" =~ ^[0-9]+$ ]] || [ "$NUM_JOBS" -le 0 ]; then
  echo "❌ Error: Number of jobs must be a positive integer, got: $NUM_JOBS"
  exit 1
fi

# Check if redis-cli is available
if ! command -v redis-cli &>/dev/null; then
  echo "❌ Error: redis-cli is not installed. Please install Redis CLI tools."
  exit 1
fi

# Test Redis connection
if ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
  echo "❌ Error: Cannot connect to Redis at $REDIS_HOST:$REDIS_PORT"
  exit 1
fi

echo "✅ Connected to Redis at $REDIS_HOST:$REDIS_PORT"
echo "📋 Scenario: $SCENARIO"
echo "🔢 Jobs per queue: $NUM_JOBS"
echo ""

# Define queue configurations
declare -A QUEUES=(
  ["high-priority"]="bull:high-priority:wait"
  ["standard"]="bull:standard:wait"
  ["low-priority"]="bull:low-priority:wait"
  ["batch"]="bull:batch:wait"
)

declare -A ACTIVE_QUEUES=(
  ["high-priority"]="bull:high-priority:active"
  ["standard"]="bull:standard:active"
  ["low-priority"]="bull:low-priority:active"
  ["batch"]="bull:batch:active"
)

# Function to add jobs to a specific queue
add_jobs_to_queue() {
  local queue_type=$1
  local queue_name=$2
  local num_jobs=$3
  local priority_level=$4

  echo "📤 Adding $num_jobs jobs to $queue_type queue ($queue_name)..."

  for i in $(seq 1 $num_jobs); do
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local job_data="{\"id\":\"${queue_type}-$i\",\"data\":\"$queue_type-job-$i\",\"priority\":\"$priority_level\",\"timestamp\":\"$timestamp\",\"queue\":\"$queue_type\"}"

    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LPUSH "$queue_name" "$job_data" >/dev/null

    if [ "$SCENARIO" = "burst" ]; then
      # No delay for burst testing
      if [ $((i % 10)) -eq 0 ]; then
        echo "  Added $i/$num_jobs jobs to $queue_type..."
      fi
    else
      echo "  Added job $i: ${queue_type}-job-$i"
      # Small delay to simulate realistic job addition
      sleep 0.1
    fi
  done

  echo "✅ Successfully added $num_jobs jobs to $queue_type queue"
}

# Add jobs based on scenario
case $SCENARIO in
high-priority)
  add_jobs_to_queue "high-priority" "${QUEUES[high - priority]}" "$NUM_JOBS" "HIGH"
  ;;
standard)
  add_jobs_to_queue "standard" "${QUEUES[standard]}" "$NUM_JOBS" "STANDARD"
  ;;
low-priority)
  add_jobs_to_queue "low-priority" "${QUEUES[low - priority]}" "$NUM_JOBS" "LOW"
  ;;
batch)
  add_jobs_to_queue "batch" "${QUEUES[batch]}" "$NUM_JOBS" "BATCH"
  ;;
mixed)
  echo "🎯 Adding jobs to all queues..."
  add_jobs_to_queue "high-priority" "${QUEUES[high - priority]}" "$NUM_JOBS" "HIGH"
  add_jobs_to_queue "standard" "${QUEUES[standard]}" "$NUM_JOBS" "STANDARD"
  add_jobs_to_queue "low-priority" "${QUEUES[low - priority]}" "$NUM_JOBS" "LOW"
  add_jobs_to_queue "batch" "${QUEUES[batch]}" "$NUM_JOBS" "BATCH"
  ;;
burst)
  echo "💥 BURST TEST: Adding $NUM_JOBS jobs to each queue rapidly..."
  add_jobs_to_queue "high-priority" "${QUEUES[high - priority]}" "$NUM_JOBS" "HIGH"
  add_jobs_to_queue "standard" "${QUEUES[standard]}" "$NUM_JOBS" "STANDARD"
  add_jobs_to_queue "low-priority" "${QUEUES[low - priority]}" "$NUM_JOBS" "LOW"
  add_jobs_to_queue "batch" "${QUEUES[batch]}" "$NUM_JOBS" "BATCH"
  ;;
esac

echo ""
echo "📊 Current Queue Status:"
echo "========================"

total_wait=0
total_active=0

for queue_type in "${!QUEUES[@]}"; do
  wait_queue="${QUEUES[$queue_type]}"
  active_queue="${ACTIVE_QUEUES[$queue_type]}"

  wait_count=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN "$wait_queue")
  active_count=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN "$active_queue")

  total_wait=$((total_wait + wait_count))
  total_active=$((total_active + active_count))

  printf "  %-15s: %3d waiting, %3d active, %3d total\n" "$queue_type" "$wait_count" "$active_count" "$((wait_count + active_count))"
done

echo "------------------------"
printf "  %-15s: %3d waiting, %3d active, %3d total\n" "TOTAL" "$total_wait" "$total_active" "$((total_wait + total_active))"

echo ""
echo "🚀 KEDA should now scale up workers based on queue lengths!"
echo ""
echo "📈 Monitor scaling with:"
echo "  kubectl get pods -n bullmq-test -w"
echo "  kubectl get scaledjobs -n bullmq-test"
echo ""
echo "🔍 Check specific ScaledJob status:"
echo "  kubectl describe scaledjob high-priority-worker -n bullmq-test"
echo "  kubectl describe scaledjob standard-priority-worker -n bullmq-test"
echo "  kubectl describe scaledjob low-priority-worker -n bullmq-test"
echo "  kubectl describe scaledjob batch-processor-worker -n bullmq-test"
echo ""
echo "📊 Monitor queue status:"
for queue_type in "${!QUEUES[@]}"; do
  wait_queue="${QUEUES[$queue_type]}"
  active_queue="${ACTIVE_QUEUES[$queue_type]}"
  echo "  redis-cli -h $REDIS_HOST -p $REDIS_PORT LLEN $wait_queue"
  echo "  redis-cli -h $REDIS_HOST -p $REDIS_PORT LLEN $active_queue"
done

echo ""
echo "✨ Test scenarios completed successfully!"
