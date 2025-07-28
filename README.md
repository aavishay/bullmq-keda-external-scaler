# KEDA Redis Bull Queue Custom Scaler

A custom external scaler for KEDA that monitors Redis Bull queues and scales Kubernetes deployments based on queue length. The scaler is configured dynamically through ScaledJob metadata, making it reusable across multiple workloads.

## Overview

This scaler monitors Redis lists for Bull queue jobs:
- **Wait queue** - Jobs waiting to be processed
- **Active queue** - Jobs currently being processed

When there are jobs in either queue, KEDA will scale up worker pods. Each pod processes exactly one job and then exits.

## Key Features

- **Dynamic Configuration** - Queue names and scaling limits are specified in ScaledJob metadata, not hardcoded in the scaler
- **Reusable Scaler** - One scaler deployment can serve multiple ScaledJobs with different queue configurations
- **Multi-tenant Ready** - Different teams can use the same scaler with different queue names
- **Fail-fast Configuration** - Required parameters are validated with clear error messages
- **Verbose Logging** - Detailed Redis operation logging for debugging
- **Job Simulation** - Worker pods consume one job and exit, simulating real workloads

## Requirements

- Kubernetes cluster with KEDA installed
- Redis server accessible from the cluster
- Docker/Podman for building the scaler image

## Configuration

### External Scaler Configuration (Environment Variables)

The external scaler only needs Redis connection details:

| Variable | Description | Example |
|----------|-------------|---------|
| `REDIS_HOST` | Redis server hostname | `redis-service.bullmq-test.svc.cluster.local` |
| `REDIS_PORT` | Redis server port (1-65535) | `6379` |

### ScaledJob Configuration (Metadata)

Each ScaledJob specifies its queue configuration through metadata:

| Metadata Key | Description | Example |
|--------------|-------------|---------|
| `scalerAddress` | External scaler service address | `redis-bull-scaler.bullmq-test.svc.cluster.local:8080` |
| `waitList` | Redis list name for waiting jobs | `bull:test-queue:wait` |
| `activeList` | Redis list name for active jobs | `bull:test-queue:active` |
| `maxPods` | Maximum number of pods to scale to (positive integer) | `"10"` |

### For add-jobs.sh script

| Variable | Description | Example |
|----------|-------------|---------|
| `REDIS_HOST` | Redis server hostname | `localhost` |
| `REDIS_PORT` | Redis server port | `6379` |
| `WAIT_QUEUE` | Redis list name for waiting jobs | `bull:test-queue:wait` |
| `ACTIVE_QUEUE` | Redis list name for active jobs | `bull:test-queue:active` |

## Quick Start

### 1. Build and Load the Scaler Image

```bash
# Using the provided build script (recommended)
./build.sh go --load                    # Build Go implementation and load into minikube
./build.sh python --tag v1.0.0         # Build Python implementation with custom tag
./build.sh go --tag latest --load      # Build Go with latest tag and load

# Or build manually
cd go
docker build -t redis-bull-scaler:latest .
# OR
cd python  
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

# Set required environment variables for testing script
export REDIS_HOST=localhost
export REDIS_PORT=6379
export WAIT_QUEUE=bull:test-queue:wait
export ACTIVE_QUEUE=bull:test-queue:active

# Add test jobs to trigger scaling
./add-jobs.sh 3

# Watch pods being created and completing jobs
kubectl get pods -n bullmq-test -w
```

## Example ScaledJob Configurations

### Basic Configuration

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: test-worker-job
  namespace: bullmq-test
spec:
  jobTargetRef:
    template:
      # ... job template ...
  triggers:
    - type: external
      metadata:
        scalerAddress: redis-bull-scaler.bullmq-test.svc.cluster.local:8080
        waitList: bull:test-queue:wait
        activeList: bull:test-queue:active
        maxPods: "10"
```

### Multiple ScaledJobs with Different Queues

```yaml
# High priority jobs
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: high-priority-worker
  namespace: bullmq-test
spec:
  triggers:
    - type: external
      metadata:
        scalerAddress: redis-bull-scaler.bullmq-test.svc.cluster.local:8080
        waitList: bull:high-priority:wait
        activeList: bull:high-priority:active
        maxPods: "20"

---
# Low priority jobs
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: low-priority-worker
  namespace: bullmq-test
spec:
  triggers:
    - type: external
      metadata:
        scalerAddress: redis-bull-scaler.bullmq-test.svc.cluster.local:8080
        waitList: bull:low-priority:wait
        activeList: bull:low-priority:active
        maxPods: "5"
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

### Dynamic Configuration

The external scaler reads queue configuration from ScaledJob metadata instead of environment variables:

1. **KEDA calls external scaler** with ScaledObjectRef containing metadata
2. **Scaler extracts configuration** from `scalerMetadata` map:
   - `waitList` - Redis list for waiting jobs
   - `activeList` - Redis list for active jobs  
   - `maxPods` - Maximum scaling limit
3. **Scaler queries Redis** using the provided queue names
4. **Scaling decisions** are made based on current queue lengths

### Scaler Implementation

The scaler implements the KEDA external scaler gRPC protocol with three main methods:

- **IsActive**: Returns `true` if there are any jobs in wait or active queues (using queue names from metadata)
- **GetMetricSpec**: Returns the metric name (`bull_queue_length`) and target size (1)
- **GetMetrics**: Returns the current total jobs in both queues, capped at `maxPods` from metadata

### Scaling Logic

- **Scale Up**: Total jobs in `wait` + `active` queues = number of pods
- **Scale Cap**: Never exceeds `maxPods` configuration from ScaledJob metadata
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

Check for missing or invalid environment variables:
```bash
kubectl logs -n bullmq-test -l app=redis-bull-scaler
```

Common errors:
- `Required environment variable REDIS_HOST is not set`
- `REDIS_PORT must be a valid port number (1-65535)`

### KEDA Not Scaling

1. Check ScaledJob status:
   ```bash
   kubectl describe scaledjob test-worker-job -n bullmq-test
   ```

2. Check for metadata validation errors in scaler logs:
   ```bash
   kubectl logs -n bullmq-test -l app=redis-bull-scaler | grep -i error
   ```

3. Common metadata errors:
   - `Required metadata waitList is missing or empty`
   - `Required metadata activeList is missing or empty`
   - `maxPods must be a positive integer`

4. Check KEDA operator logs:
   ```bash
   kubectl logs -n keda-system -l app=keda-operator
   ```

### Redis Connection Issues

- Ensure Redis service is running and accessible
- Check Redis hostname and port in deployment manifest
- Verify network policies allow communication
- Check Redis connectivity from scaler pods:
  ```bash
  kubectl exec -n bullmq-test deployment/redis-bull-scaler -- redis-cli -h redis-service.bullmq-test.svc.cluster.local -p 6379 ping
  ```

### Metadata Configuration Issues

Verify ScaledJob metadata is correctly specified:
```bash
kubectl get scaledjob test-worker-job -n bullmq-test -o yaml
```

Required metadata fields:
- `scalerAddress`
- `waitList`
- `activeList`
- `maxPods` (must be a string representation of a positive integer)

## Development

### Testing Locally

```bash
# Go implementation
cd go
export REDIS_HOST=localhost
export REDIS_PORT=6379
go run redis_bull_scaler.go

# Python implementation  
cd python
export REDIS_HOST=localhost
export REDIS_PORT=6379
pip install -r requirements.txt
python redis_bull_scaler.py

# Or test with Docker locally
docker run --rm \
  -e REDIS_HOST=host.docker.internal \
  -e REDIS_PORT=6379 \
  -p 8080:8080 \
  redis-bull-scaler:latest
```

### Customization

To adapt this scaler for your use case:

1. **Different Queue Names**: Update the `waitList` and `activeList` in your ScaledJob metadata
2. **Different Scaling Logic**: Modify the `GetMetrics` method in the scaler implementation
3. **Additional Metadata**: Add new metadata fields and update the scaler to use them
4. **Multiple Metrics**: Return multiple metrics from `GetMetricSpec` for complex scaling decisions

### Adding New Features

The metadata-based approach makes it easy to add new configuration options:

1. Add new metadata keys to your ScaledJob
2. Extract them in the scaler using `getMetadataValue()`
3. Use the values in your scaling logic
4. Add validation as needed

## Migration from Environment Variable Configuration

If you have an existing deployment using environment variables, here's how to migrate:

1. **Update ScaledJob**: Add queue configuration to metadata
2. **Update Scaler Deployment**: Remove queue-specific environment variables, keep only Redis connection details
3. **Test Configuration**: Verify the scaler can read metadata correctly
4. **Deploy Changes**: Apply updated manifests

The new approach is backward compatible - you can migrate one ScaledJob at a time.

## Advanced Usage

### Build Script

The project includes a comprehensive build script for Go and Python implementations:

```bash
# Build Go implementation (default)
./build.sh

# Build Python implementation
./build.sh python

# Build with custom tag and load into minikube
./build.sh go --tag v1.2.3 --load

# Build and push to registry
./build.sh python --tag production --push

# Build without cache for clean build
./build.sh go --no-cache

# Multi-platform build
./build.sh go --platform linux/amd64,linux/arm64
```

**Note:** Both implementations build to the same image name `redis-bull-scaler` - choose either Go or Python based on your preference.

### Testing Multiple Queue Scenarios

Use the enhanced testing script for complex scenarios:

```bash
# Test mixed priority queues
cd examples
export REDIS_HOST=localhost
export REDIS_PORT=6379

# Add jobs to all queues
./add-test-jobs.sh mixed 5

# Test high priority only
./add-test-jobs.sh high-priority 10

# Burst testing for load
./add-test-jobs.sh burst 50

# Deploy multiple ScaledJobs example
kubectl apply -f examples/multiple-scaledjobs.yaml
```

### Implementation Choice

Choose either Go or Python implementation based on your preferences:
- **Go**: Better performance, smaller image size, faster startup
- **Python**: More readable code, easier to modify, familiar to more developers

Both implementations provide identical functionality and use the same Docker image name.

### Validation

Test the build process and validate all changes with the included validation script:

```bash
# Run all validation tests
./validate-build.sh

# This will test:
# - Go implementation builds correctly
# - Python implementation builds correctly  
# - Consistent image naming (redis-bull-scaler)
# - Build script argument validation
# - File structure validation
```

## License

This project is provided as-is for educational and development purposes.