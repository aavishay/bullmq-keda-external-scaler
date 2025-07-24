# KEDA Redis Bull Queue Custom Scaler

A custom external scaler for KEDA that monitors Redis Bull queues and scales Kubernetes deployments based on queue length.

## Overview

This scaler monitors two Redis lists:
- `bull:test-queue:wait` - Jobs waiting to be processed
- `bull:test-queue:active` - Jobs currently being processed

When there are jobs in either queue, KEDA will scale up worker pods. Each pod processes exactly one job and then exits.

## Features

- **Fail-fast configuration** - All environment variables are required with no defaults
- **Input validation** - Validates port numbers and positive integers
- **Verbose logging** - Detailed Redis operation logging for debugging
- **Job simulation** - Worker pods consume one job and exit, simulating real workloads
- **Queue monitoring** - Monitors both waiting and active job queues

## Requirements

- Kubernetes cluster with KEDA installed
- Redis server accessible from the cluster
- Docker/Podman for building the scaler image

## Configuration

All configuration is done via environment variables. **No defaults are provided** - all variables are required.

### Required Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `REDIS_HOST` | Redis server hostname | `redis-service.bullmq-test.svc.cluster.local` |
| `REDIS_PORT` | Redis server port (1-65535) | `6379` |
| `WAIT_LIST` | Redis list name for waiting jobs | `bull:test-queue:wait` |
| `ACTIVE_LIST` | Redis list name for active jobs | `bull:test-queue:active` |
| `MAX_PODS` | Maximum number of pods to scale to (positive integer) | `10` |

### For add-jobs.sh script

| Variable | Description | Example |
|----------|-------------|---------|
| `WAIT_QUEUE` | Same as WAIT_LIST above | `bull:test-queue:wait` |
| `ACTIVE_QUEUE` | Same as ACTIVE_LIST above | `bull:test-queue:active` |

## Quick Start

### 1. Build and Load the Scaler Image

```bash
# Build the Docker image
docker build -t redis-bull-scaler:latest .

# Load into minikube (if using minikube)
minikube image load redis-bull-scaler:latest
```

### 2. Deploy to Kubernetes

```bash
# Deploy all Kubernetes manifests
kubectl apply -f k8s/

# Or deploy individually
kubectl apply -f k8s/redis-bull-scaler-service.yaml
kubectl apply -f k8s/redis-bull-scaler-deployment.yaml
kubectl apply -f k8s/test-scaledjob.yaml
```

### 3. Test the Scaling

```bash
# Port-forward to Redis
kubectl port-forward -n bullmq-test svc/redis-service 6379:6379

# Set required environment variables
export REDIS_HOST=localhost
export REDIS_PORT=6379
export WAIT_QUEUE=bull:test-queue:wait
export ACTIVE_QUEUE=bull:test-queue:active

# Add test jobs to trigger scaling
./add-jobs.sh 3

# Watch pods being created and completing jobs
kubectl get pods -n bullmq-test -w
```

## Monitoring

### Check Scaler Status

```bash
# Check scaler logs
kubectl logs -n bullmq-test -l app=redis-bull-scaler -f

# Check ScaledJob status
kubectl describe scaledjob test-worker-job -n bullmq-test

# Check current queue lengths
redis-cli -h localhost -p 6379 LLEN bull:test-queue:wait
redis-cli -h localhost -p 6379 LLEN bull:test-queue:active
```

### Expected Behavior

1. **No jobs in queues** → 0 worker pods
2. **Jobs added to wait queue** → KEDA scales up worker pods (1 pod per job)
3. **Worker pods start** → Each pod:
   - Pops one job from `wait` queue
   - Moves it to `active` queue
   - Processes for 10 seconds
   - Removes from `active` queue
   - Exits (pod completes)
4. **All jobs completed** → KEDA scales down to 0 after cooldown period

## Project Structure

```
bullmq-keda-external-scaler/
├── README.md                              # This file
├── add-jobs.sh                           # Helper script to add test jobs
├── go/                                   # Go implementation
│   ├── Dockerfile
│   ├── externalscaler.proto              # gRPC protocol definition
│   ├── go.mod
│   └── redis_bull_scaler.go
├── python/                               # Python implementation
│   ├── Dockerfile
│   ├── externalscaler.proto              # gRPC protocol definition
│   ├── redis_bull_scaler.py
│   └── requirements.txt
└── k8s/                                  # Kubernetes manifests
    ├── redis-bull-scaler-deployment.yaml
    ├── redis-bull-scaler-service.yaml
    └── test-scaledjob.yaml
```

## How It Works

### Scaler Implementation

The scaler implements the KEDA external scaler gRPC protocol with three main methods:

- **IsActive**: Returns `true` if there are any jobs in wait or active queues
- **GetMetricSpec**: Returns the metric name (`bull_queue_length`) and target size (1)
- **GetMetrics**: Returns the current total jobs in both queues, capped at `MAX_PODS`

### Scaling Logic

- **Scale Up**: Total jobs in `wait` + `active` queues = number of pods
- **Scale Cap**: Never exceeds `MAX_PODS` configuration
- **Scale Down**: When queues are empty, KEDA scales to 0 after cooldown

### Job Processing

The test worker deployment simulates realistic job processing:

1. Uses Redis image with `redis-cli` available
2. Pops one job from the wait queue (`RPOP`)
3. Adds job to active queue for tracking (`LPUSH`)
4. Simulates 10 seconds of processing
5. Removes job from active queue (`LREM`)
6. Exits with status 0

## Troubleshooting

### Scaler Won't Start

Check for missing environment variables:
```bash
kubectl logs -n bullmq-test -l app=redis-bull-scaler
```

Common errors:
- `Required environment variable REDIS_HOST is not set`
- `MAX_PODS must be a positive integer`
- `REDIS_PORT must be a valid port number (1-65535)`

### KEDA Not Scaling

1. Check ScaledJob status:
   ```bash
   kubectl describe scaledjob test-worker-job -n bullmq-test
   ```

2. Check KEDA operator logs:
   ```bash
   kubectl logs -n keda-system -l app=keda-operator
   ```

3. Verify scaler connectivity:
   ```bash
   kubectl port-forward -n bullmq-test svc/redis-bull-scaler 8080:8080
   # Test gRPC endpoints manually if needed
   ```

### Redis Connection Issues

- Ensure Redis service is running and accessible
- Check Redis hostname and port in deployment manifest
- Verify network policies allow communication

## Development

### Testing Locally

```bash
# Install dependencies
pip install grpcio redis

# Set required environment variables
export REDIS_HOST=localhost
export REDIS_PORT=6379
export WAIT_LIST=bull:test-queue:wait
export ACTIVE_LIST=bull:test-queue:active
export MAX_PODS=10

# Run the scaler
python redis_bull_scaler.py
```

### Customization

To adapt this scaler for your use case:

1. Update the Redis list names in the environment variables
2. Modify the scaling logic in `GetMetrics` method
3. Adjust the `MAX_PODS` value based on your requirements
4. Update the worker deployment to match your job processing logic

## License

This project is provided as-is for educational and development purposes.