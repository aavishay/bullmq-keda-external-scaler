# Migration Guide: Environment Variables to ScaledJob Metadata

This guide explains how to migrate from the old environment variable-based configuration to the new metadata-based configuration for the BullMQ KEDA External Scaler.

## Overview of Changes

The external scaler has been updated to read queue configuration from ScaledJob metadata instead of environment variables. This change provides several benefits:

- **Dynamic Configuration**: Each ScaledJob can specify different queue names
- **Reusable Scaler**: One scaler deployment serves multiple ScaledJobs
- **Multi-tenancy**: Different teams can use different queue configurations
- **Better Separation**: Queue config lives with workload, not infrastructure

## Migration Steps

### 1. Before Migration (Old Approach)

**External Scaler Deployment:**
```yaml
env:
  - name: REDIS_HOST
    value: "redis-service.bullmq-test.svc.cluster.local"
  - name: REDIS_PORT
    value: "6379"
  - name: WAIT_LIST
    value: "bull:test-queue:wait"
  - name: ACTIVE_LIST
    value: "bull:test-queue:active"
  - name: MAX_PODS
    value: "10"
```

**ScaledJob:**
```yaml
triggers:
  - type: external
    metadata:
      scalerAddress: redis-bull-scaler.bullmq-test.svc.cluster.local:8080
```

### 2. After Migration (New Approach)

**External Scaler Deployment:**
```yaml
env:
  - name: REDIS_HOST
    value: "redis-service.bullmq-test.svc.cluster.local"
  - name: REDIS_PORT
    value: "6379"
  # WAIT_LIST, ACTIVE_LIST, MAX_PODS removed
```

**ScaledJob:**
```yaml
triggers:
  - type: external
    metadata:
      scalerAddress: redis-bull-scaler.bullmq-test.svc.cluster.local:8080
      waitList: bull:test-queue:wait
      activeList: bull:test-queue:active
      maxPods: "10"
```

### 3. Step-by-Step Migration Process

#### Step 1: Update ScaledJob Configuration
Add the queue configuration to your ScaledJob metadata:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: your-worker-job
  namespace: your-namespace
spec:
  # ... existing job configuration ...
  triggers:
    - type: external
      metadata:
        scalerAddress: redis-bull-scaler.your-namespace.svc.cluster.local:8080
        waitList: "your-wait-queue-name"      # Move from WAIT_LIST env var
        activeList: "your-active-queue-name"  # Move from ACTIVE_LIST env var
        maxPods: "10"                         # Move from MAX_PODS env var
```

#### Step 2: Update External Scaler Deployment
Remove queue-specific environment variables:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-bull-scaler
  namespace: your-namespace
spec:
  template:
    spec:
      containers:
        - name: scaler
          image: redis-bull-scaler:latest
          env:
            - name: REDIS_HOST
              value: "your-redis-host"
            - name: REDIS_PORT
              value: "6379"
            # Remove these:
            # - name: WAIT_LIST
            # - name: ACTIVE_LIST  
            # - name: MAX_PODS
```

#### Step 3: Deploy Updated Scaler Image
Ensure you're using the updated scaler image that supports metadata-based configuration:

```bash
# Build updated image
docker build -t redis-bull-scaler:latest .

# Load into cluster (minikube example)
minikube image load redis-bull-scaler:latest

# Update deployment
kubectl apply -f k8s/redis-bull-scaler-deployment.yaml
```

#### Step 4: Apply Updated ScaledJob
```bash
kubectl apply -f your-scaledjob.yaml
```

#### Step 5: Verify Migration
Check that the scaler is reading metadata correctly:

```bash
# Check scaler logs for metadata reading
kubectl logs -n your-namespace -l app=redis-bull-scaler | grep metadata

# Check ScaledJob status
kubectl describe scaledjob your-worker-job -n your-namespace

# Test scaling by adding jobs
./add-jobs.sh 5
```

## Configuration Reference

### Required Metadata Fields

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `scalerAddress` | string | External scaler service address | `redis-bull-scaler.bullmq-test.svc.cluster.local:8080` |
| `waitList` | string | Redis list name for waiting jobs | `bull:my-queue:wait` |
| `activeList` | string | Redis list name for active jobs | `bull:my-queue:active` |
| `maxPods` | string | Maximum pods to scale to (as string) | `"10"` |

### Environment Variables (Scaler Deployment)

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `REDIS_HOST` | Yes | Redis server hostname | `redis.default.svc.cluster.local` |
| `REDIS_PORT` | Yes | Redis server port (1-65535) | `6379` |

## Validation and Error Handling

The updated scaler includes comprehensive validation:

### Metadata Validation Errors
- `Required metadata waitList is missing or empty`
- `Required metadata activeList is missing or empty`
- `Required metadata maxPods is missing or empty`
- `maxPods must be a positive integer, got: [value]`

### Environment Variable Validation Errors
- `Required environment variable REDIS_HOST is not set`
- `Required environment variable REDIS_PORT is not set`
- `REDIS_PORT must be a valid port number (1-65535), got: [value]`

## Multiple ScaledJobs Example

One of the key benefits is supporting multiple ScaledJobs with different configurations:

```yaml
# High priority workers
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: high-priority-worker
spec:
  triggers:
    - type: external
      metadata:
        scalerAddress: redis-bull-scaler.bullmq-test.svc.cluster.local:8080
        waitList: bull:high-priority:wait
        activeList: bull:high-priority:active
        maxPods: "20"

---
# Standard priority workers  
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: standard-priority-worker
spec:
  triggers:
    - type: external
      metadata:
        scalerAddress: redis-bull-scaler.bullmq-test.svc.cluster.local:8080
        waitList: bull:standard:wait
        activeList: bull:standard:active
        maxPods: "10"
```

## Troubleshooting Migration Issues

### Common Issues

#### 1. Scaler Not Reading Metadata
**Symptoms:** Scaler logs show environment variable errors
**Solution:** Ensure you're using the updated scaler image

#### 2. Invalid Metadata Format
**Symptoms:** ScaledJob not scaling, metadata validation errors in logs
**Solution:** Verify all required metadata fields are present and correct

#### 3. String vs Integer Values
**Symptoms:** `maxPods must be a positive integer` error
**Solution:** Ensure `maxPods` is quoted as a string in YAML: `maxPods: "10"`

#### 4. Missing scalerAddress
**Symptoms:** KEDA can't connect to external scaler
**Solution:** Verify the service name and port in `scalerAddress`

### Debugging Commands

```bash
# Check scaler pod logs
kubectl logs -n your-namespace deployment/redis-bull-scaler

# Check ScaledJob status
kubectl describe scaledjob your-worker-job -n your-namespace

# Check KEDA operator logs
kubectl logs -n keda-system -l app=keda-operator

# Verify scaler service connectivity
kubectl port-forward -n your-namespace svc/redis-bull-scaler 8080:8080

# Check metadata in ScaledJob
kubectl get scaledjob your-worker-job -n your-namespace -o yaml
```

## Rollback Plan

If you need to rollback to the old approach:

1. **Revert ScaledJob:** Remove metadata fields from triggers
2. **Revert Scaler Deployment:** Add environment variables back
3. **Deploy Old Image:** Use the previous scaler image version
4. **Apply Changes:** Update both resources

## Testing Migration

Use the provided test scripts to verify your migration:

```bash
# Set environment variables for testing
export REDIS_HOST=localhost
export REDIS_PORT=6379
export WAIT_QUEUE=bull:your-queue:wait
export ACTIVE_QUEUE=bull:your-queue:active

# Add test jobs
./add-jobs.sh 5

# Monitor scaling
kubectl get pods -n your-namespace -w
```

## Benefits Summary

After migration, you'll have:

- ✅ **Flexible Configuration**: Different ScaledJobs can use different queues
- ✅ **Simplified Deployment**: Scaler only needs Redis connection details
- ✅ **Better Multi-tenancy**: Teams can configure their own queues
- ✅ **Easier Management**: No need to restart scaler for queue changes
- ✅ **Improved Separation**: Queue config with workload, not infrastructure

## Support

If you encounter issues during migration:

1. Check the troubleshooting section above
2. Review the updated README.md for examples
3. Use the examples in the `examples/` directory
4. Check scaler and KEDA logs for detailed error messages

The migration maintains backward compatibility during transition - you can migrate one ScaledJob at a time without affecting others.