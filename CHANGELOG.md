# Changelog

All notable changes to the BullMQ KEDA External Scaler project.

## [2.0.0] - 2024-07-28

### 🚀 Major Changes - Metadata-Based Configuration

#### Breaking Changes
- **BREAKING**: Queue configuration moved from environment variables to ScaledJob metadata
- **BREAKING**: External scaler deployment no longer requires `WAIT_LIST`, `ACTIVE_LIST`, or `MAX_PODS` environment variables
- **BREAKING**: ScaledJob configuration now requires `waitList`, `activeList`, and `maxPods` in trigger metadata

#### Added
- **Dynamic Configuration**: Each ScaledJob can now specify different queue names and scaling limits
- **Reusable Scaler**: One external scaler deployment can serve multiple ScaledJobs with different configurations
- **Multi-tenancy Support**: Different teams can use the same scaler with different queue configurations
- **Enhanced Validation**: Comprehensive metadata validation with clear error messages
- **Improved Logging**: Added ScaledObject namespace/name to all log messages for better debugging

#### Updated Files
- `go/redis_bull_scaler.go`: Complete rewrite to use metadata-based configuration
- `python/redis_bull_scaler.py`: Complete rewrite to use metadata-based configuration
- `k8s/test-scaledjob.yaml`: Added queue configuration to trigger metadata
- `k8s/redis-bull-scaler-deployment.yaml`: Removed queue-specific environment variables
- `README.md`: Comprehensive update reflecting new configuration approach

#### New Files
- `MIGRATION.md`: Step-by-step migration guide from environment variables to metadata
- `examples/multiple-scaledjobs.yaml`: Complete example showing multiple ScaledJobs with different priorities
- `examples/add-test-jobs.sh`: Enhanced testing script for multiple queue scenarios
- `build.sh`: Comprehensive build script for both Go and Python implementations
- `validate-build.sh`: Validation script to test build process and configuration

### 🔧 Technical Improvements

#### Go Implementation (`go/redis_bull_scaler.go`)
- Removed `waitList`, `activeList`, `maxPods` fields from server struct
- Added `getMetadataValue()` function for safe metadata extraction
- Added `validatePortNumber()` function for port validation
- Enhanced error handling with detailed error messages
- Improved gRPC method implementations with metadata support
- Added comprehensive logging with request context

#### Python Implementation (`python/redis_bull_scaler.py`)
- Removed queue-specific environment variable requirements
- Added `get_metadata_value()` and `validate_max_pods()` functions
- Enhanced error handling with proper gRPC status codes
- Improved validation and logging throughout
- Added comprehensive metadata extraction and validation

#### Build System
- **New**: `build.sh` script supporting both Go and Python implementations
- **Feature**: Support for custom tags, pushing to registry, loading into minikube
- **Feature**: Multi-platform build support
- **Feature**: No-cache build option
- **Improvement**: Consistent image naming (`redis-bull-scaler`) regardless of implementation

#### Testing & Validation
- **New**: `validate-build.sh` script for comprehensive build validation
- **New**: `examples/add-test-jobs.sh` supporting multiple test scenarios:
  - `high-priority`: Add jobs only to high priority queue
  - `standard`: Add jobs only to standard priority queue  
  - `low-priority`: Add jobs only to low priority queue
  - `batch`: Add jobs only to batch processing queue
  - `mixed`: Add jobs to all queues
  - `burst`: Load testing with many jobs
- **New**: Complete multi-ScaledJob example with 4 different priority levels

### 📖 Documentation

#### Updated Documentation
- **README.md**: Complete rewrite reflecting metadata-based approach
- **Added**: Migration guide with step-by-step instructions
- **Added**: Multiple ScaledJob configuration examples
- **Added**: Advanced usage patterns and best practices
- **Added**: Comprehensive troubleshooting for metadata validation
- **Added**: Build script usage examples

#### New Documentation
- **MIGRATION.md**: Detailed migration guide from v1.x to v2.x
- **Examples**: Real-world configuration examples for different use cases
- **Validation**: Testing procedures and validation scripts

### 🏗️ Infrastructure Changes

#### Kubernetes Manifests
- **ScaledJob**: Now includes `waitList`, `activeList`, `maxPods` in trigger metadata
- **Deployment**: Simplified to only require Redis connection details
- **Examples**: Added comprehensive multi-tenant examples

#### Docker Images
- **Consistent Naming**: Both Go and Python implementations build to `redis-bull-scaler`
- **Optimization**: Improved build process with better caching
- **Validation**: Automated testing of image functionality

### 🔄 Migration Path

#### From v1.x (Environment Variables) to v2.x (Metadata)
1. Add queue configuration to ScaledJob metadata
2. Remove queue-specific environment variables from scaler deployment
3. Update to new scaler image
4. Validate configuration and test scaling

#### Backward Compatibility
- Migration can be done one ScaledJob at a time
- Clear validation errors guide configuration issues
- Comprehensive migration documentation provided

### 🎯 Benefits

#### For Operators
- **Simplified Deployment**: External scaler only needs Redis connection details
- **Better Resource Utilization**: One scaler serves multiple workloads
- **Easier Management**: No scaler restarts needed for queue changes

#### For Developers  
- **Flexible Configuration**: Each ScaledJob can specify its own queue names
- **Team Independence**: Different teams can use different queue configurations
- **Better Separation**: Queue config lives with workload, not infrastructure

#### For DevOps
- **Multi-tenancy**: Support for multiple teams/environments
- **Easier Debugging**: Enhanced logging with context information
- **Validation**: Clear error messages for configuration issues

### 📋 Example Configuration

#### Before (v1.x)
```yaml
# External Scaler Deployment
env:
  - name: WAIT_LIST
    value: "bull:test-queue:wait"
  - name: ACTIVE_LIST  
    value: "bull:test-queue:active"
  - name: MAX_PODS
    value: "10"

# ScaledJob
triggers:
  - type: external
    metadata:
      scalerAddress: redis-bull-scaler:8080
```

#### After (v2.x)
```yaml
# External Scaler Deployment
env:
  - name: REDIS_HOST
    value: "redis-service"
  - name: REDIS_PORT
    value: "6379"

# ScaledJob
triggers:
  - type: external
    metadata:
      scalerAddress: redis-bull-scaler:8080
      waitList: bull:test-queue:wait
      activeList: bull:test-queue:active
      maxPods: "10"
```

### 🧪 Testing

#### Validation Scripts
- **build.sh**: Comprehensive build script with validation
- **validate-build.sh**: Full build process validation
- **examples/add-test-jobs.sh**: Multi-scenario testing

#### Test Coverage
- ✅ Go implementation build and functionality
- ✅ Python implementation build and functionality  
- ✅ Consistent image naming
- ✅ Metadata validation
- ✅ Error handling
- ✅ Multi-ScaledJob scenarios

### 🔮 Future Enhancements

#### Planned Features
- Support for additional metadata parameters
- Enhanced scaling strategies
- Metrics and monitoring integration
- Additional queue backends

This release represents a major architectural improvement, making the scaler more flexible, reusable, and suitable for multi-tenant environments while maintaining the same core functionality.