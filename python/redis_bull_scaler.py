import grpc
from concurrent import futures
import redis
import os
import logging
import time
import externalscaler_pb2
import externalscaler_pb2_grpc

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration via environment variables - fail fast if not defined
def get_required_env(var_name, var_type=str):
    value = os.getenv(var_name)
    if value is None:
        logger.error(f"Required environment variable {var_name} is not set")
        raise ValueError(f"Missing required environment variable: {var_name}")

    if var_type == int:
        try:
            int_value = int(value)
            if var_name == "REDIS_PORT" and (int_value <= 0 or int_value > 65535):
                logger.error(f"Environment variable {var_name} must be a valid port number (1-65535), got: {value}")
                raise ValueError(f"REDIS_PORT must be a valid port number (1-65535), got: {value}")
            return int_value
        except ValueError as e:
            if "valid port number" in str(e):
                raise e
            logger.error(f"Environment variable {var_name} must be an integer, got: {value}")
            raise ValueError(f"Invalid integer value for {var_name}: {value}")

    return value

# Only Redis connection configuration is required from environment variables
REDIS_HOST = get_required_env("REDIS_HOST")
REDIS_PORT = get_required_env("REDIS_PORT", int)

# Redis connection with verbose logging
class VerboseRedis:
    def __init__(self, redis_client):
        self.redis_client = redis_client

    def ping(self):
        logger.info(f"[REDIS] Executing PING command to {REDIS_HOST}:{REDIS_PORT}")
        try:
            result = self.redis_client.ping()
            logger.info(f"[REDIS] PING successful: {result}")
            return result
        except Exception as e:
            logger.error(f"[REDIS] PING failed: {e}")
            raise

    def llen(self, key):
        logger.info(f"[REDIS] Executing LLEN command for key: {key}")
        try:
            result = self.redis_client.llen(key)
            logger.info(f"[REDIS] LLEN '{key}' returned: {result}")
            return result
        except Exception as e:
            logger.error(f"[REDIS] LLEN '{key}' failed: {e}")
            raise

# Initialize Redis connection
try:
    redis_client = redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        decode_responses=True,
        socket_timeout=5,
        socket_connect_timeout=5
    )
    r = VerboseRedis(redis_client)
    r.ping()
    logger.info(f"Successfully connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
    logger.info("External scaler ready - queue configuration will come from ScaledJob metadata")
except redis.ConnectionError as e:
    logger.error(f"Failed to connect to Redis at {REDIS_HOST}:{REDIS_PORT}: {e}")
    r = None

def get_metadata_value(metadata, key):
    """Extract and validate metadata from ScaledObjectRef"""
    if key not in metadata or not metadata[key]:
        raise ValueError(f"Required metadata {key} is missing or empty")
    return metadata[key]

def validate_max_pods(max_pods_str):
    """Validate maxPods parameter"""
    try:
        max_pods = int(max_pods_str)
        if max_pods <= 0:
            raise ValueError(f"maxPods must be a positive integer, got: {max_pods_str}")
        return max_pods
    except ValueError as e:
        if "positive integer" in str(e):
            raise e
        raise ValueError(f"maxPods must be a valid integer, got: {max_pods_str}")

class ExternalScalerServicer(externalscaler_pb2_grpc.ExternalScalerServicer):

    def IsActive(self, request, context):
        """
        Returns true if there is at least one item in either wait or active list.
        """
        logger.info(f"[GRPC] IsActive called for ScaledObject: {request.namespace}/{request.name}")
        try:
            if r is None:
                logger.error("[IS-ACTIVE] Redis connection not available")
                return externalscaler_pb2.IsActiveResponse(result=False)

            # Get queue names from metadata
            try:
                wait_list = get_metadata_value(request.scalerMetadata, "waitList")
                active_list = get_metadata_value(request.scalerMetadata, "activeList")
            except ValueError as e:
                logger.error(f"[IS-ACTIVE] Metadata error: {e}")
                context.set_code(grpc.StatusCode.INVALID_ARGUMENT)
                context.set_details(str(e))
                return externalscaler_pb2.IsActiveResponse(result=False)

            logger.info(f"[IS-ACTIVE] Using queues: wait='{wait_list}', active='{active_list}'")

            wait_len = r.llen(wait_list)
            active_len = r.llen(active_list)
            total = wait_len + active_len
            result = total > 0

            logger.info(f"[IS-ACTIVE] Result: wait={wait_len}, active={active_len}, total={total}, is_active={result}")
            return externalscaler_pb2.IsActiveResponse(result=result)
        except Exception as e:
            logger.error(f"[IS-ACTIVE] Error: {e}")
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details(f"Failed to check if active: {str(e)}")
            return externalscaler_pb2.IsActiveResponse(result=False)

    def GetMetricSpec(self, request, context):
        """
        Returns the metric spec for KEDA. Each pod handles 1 job.
        """
        logger.info(f"[GRPC] GetMetricSpec called for ScaledObject: {request.namespace}/{request.name}")
        try:
            metric_spec = externalscaler_pb2.MetricSpec(
                metricName="bull_queue_length",
                targetSize=1
            )
            logger.info(f"[GET-METRIC-SPEC] Returning spec: metricName=bull_queue_length, targetSize=1")
            return externalscaler_pb2.GetMetricSpecResponse(metricSpecs=[metric_spec])
        except Exception as e:
            logger.error(f"[GET-METRIC-SPEC] Error: {e}")
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details(f"Failed to get metric spec: {str(e)}")
            return externalscaler_pb2.GetMetricSpecResponse()

    def GetMetrics(self, request, context):
        """
        Returns the current metric value: total jobs in wait+active, capped at maxPods.
        """
        logger.info(f"[GRPC] GetMetrics called for ScaledObject: {request.scaledObjectRef.namespace}/{request.scaledObjectRef.name}")
        try:
            if r is None:
                logger.error("[GET-METRICS] Redis connection not available")
                metric_value = externalscaler_pb2.MetricValue(
                    metricName="bull_queue_length",
                    metricValue=0
                )
                return externalscaler_pb2.GetMetricsResponse(metricValues=[metric_value])

            # Get configuration from metadata
            try:
                wait_list = get_metadata_value(request.scaledObjectRef.scalerMetadata, "waitList")
                active_list = get_metadata_value(request.scaledObjectRef.scalerMetadata, "activeList")
                max_pods_str = get_metadata_value(request.scaledObjectRef.scalerMetadata, "maxPods")
                max_pods = validate_max_pods(max_pods_str)
            except ValueError as e:
                logger.error(f"[GET-METRICS] Metadata error: {e}")
                context.set_code(grpc.StatusCode.INVALID_ARGUMENT)
                context.set_details(str(e))
                metric_value = externalscaler_pb2.MetricValue(
                    metricName="bull_queue_length",
                    metricValue=0
                )
                return externalscaler_pb2.GetMetricsResponse(metricValues=[metric_value])

            logger.info(f"[GET-METRICS] Using queues: wait='{wait_list}', active='{active_list}', maxPods={max_pods}")

            wait_len = r.llen(wait_list)
            active_len = r.llen(active_list)
            total = wait_len + active_len
            metric_value_int = min(total, max_pods)

            metric_value = externalscaler_pb2.MetricValue(
                metricName="bull_queue_length",
                metricValue=metric_value_int
            )

            logger.info(f"[GET-METRICS] Final result: wait={wait_len}, active={active_len}, total={total}, capped_value={metric_value_int}, max_pods={max_pods}")
            return externalscaler_pb2.GetMetricsResponse(metricValues=[metric_value])
        except Exception as e:
            logger.error(f"[GET-METRICS] Error: {e}")
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details(f"Failed to get metrics: {str(e)}")
            metric_value = externalscaler_pb2.MetricValue(
                metricName="bull_queue_length",
                metricValue=0
            )
            return externalscaler_pb2.GetMetricsResponse(metricValues=[metric_value])

def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))

    # Add the external scaler servicer
    externalscaler_pb2_grpc.add_ExternalScalerServicer_to_server(
        ExternalScalerServicer(), server
    )

    # Listen on port 8080
    listen_addr = "0.0.0.0:8080"
    server.add_insecure_port(listen_addr)

    logger.info(f"Starting gRPC server on {listen_addr}")
    logger.info(f"Redis config: {REDIS_HOST}:{REDIS_PORT}")
    logger.info("Queue configuration will be provided via ScaledJob metadata")

    server.start()

    try:
        while True:
            time.sleep(86400)  # Sleep for a day
    except KeyboardInterrupt:
        logger.info("Shutting down gRPC server")
        server.stop(0)

if __name__ == "__main__":
    serve()
