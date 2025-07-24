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
            if var_name == "MAX_PODS" and int_value <= 0:
                logger.error(f"Environment variable {var_name} must be a positive integer, got: {value}")
                raise ValueError(f"MAX_PODS must be a positive integer, got: {value}")
            if var_name == "REDIS_PORT" and (int_value <= 0 or int_value > 65535):
                logger.error(f"Environment variable {var_name} must be a valid port number (1-65535), got: {value}")
                raise ValueError(f"REDIS_PORT must be a valid port number (1-65535), got: {value}")
            return int_value
        except ValueError as e:
            if "positive integer" in str(e) or "valid port number" in str(e):
                raise e
            logger.error(f"Environment variable {var_name} must be an integer, got: {value}")
            raise ValueError(f"Invalid integer value for {var_name}: {value}")

    return value

REDIS_HOST = get_required_env("REDIS_HOST")
REDIS_PORT = get_required_env("REDIS_PORT", int)
WAIT_LIST = get_required_env("WAIT_LIST")
ACTIVE_LIST = get_required_env("ACTIVE_LIST")
MAX_PODS = get_required_env("MAX_PODS", int)

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
except redis.ConnectionError as e:
    logger.error(f"Failed to connect to Redis at {REDIS_HOST}:{REDIS_PORT}: {e}")
    r = None

class ExternalScalerServicer(externalscaler_pb2_grpc.ExternalScalerServicer):

    def IsActive(self, request, context):
        """
        Returns true if there is at least one item in either wait or active list.
        """
        logger.info("[GRPC] IsActive called")
        try:
            if r is None:
                logger.error("[IS-ACTIVE] Redis connection not available")
                return externalscaler_pb2.IsActiveResponse(result=False)

            logger.info(f"[IS-ACTIVE] Checking queue lengths for WAIT_LIST='{WAIT_LIST}' and ACTIVE_LIST='{ACTIVE_LIST}'")
            wait_len = r.llen(WAIT_LIST)
            active_len = r.llen(ACTIVE_LIST)
            total = wait_len + active_len
            result = total > 0

            logger.info(f"[IS-ACTIVE] Result: wait={wait_len}, active={active_len}, total={total}, is_active={result}")
            return externalscaler_pb2.IsActiveResponse(result=result)
        except Exception as e:
            logger.error(f"[IS-ACTIVE] Error: {e}")
            return externalscaler_pb2.IsActiveResponse(result=False)

    def GetMetricSpec(self, request, context):
        """
        Returns the metric spec for KEDA. Each pod handles 1 job.
        """
        logger.info("[GRPC] GetMetricSpec called")
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
        Returns the current metric value: total jobs in wait+active, capped at MAX_PODS.
        """
        logger.info("[GRPC] GetMetrics called")
        try:
            if r is None:
                logger.error("[GET-METRICS] Redis connection not available")
                metric_value = externalscaler_pb2.MetricValue(
                    metricName="bull_queue_length",
                    metricValue=0
                )
                return externalscaler_pb2.GetMetricsResponse(metricValues=[metric_value])

            logger.info(f"[GET-METRICS] Checking queue lengths for WAIT_LIST='{WAIT_LIST}' and ACTIVE_LIST='{ACTIVE_LIST}'")
            wait_len = r.llen(WAIT_LIST)
            active_len = r.llen(ACTIVE_LIST)
            total = wait_len + active_len
            metric_value_int = min(total, MAX_PODS)

            metric_value = externalscaler_pb2.MetricValue(
                metricName="bull_queue_length",
                metricValue=metric_value_int
            )

            logger.info(f"[GET-METRICS] Final result: wait={wait_len}, active={active_len}, total={total}, capped_value={metric_value_int}, max_pods={MAX_PODS}")
            return externalscaler_pb2.GetMetricsResponse(metricValues=[metric_value])
        except Exception as e:
            logger.error(f"[GET-METRICS] Error: {e}")
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
    logger.info(f"Queue config: WAIT='{WAIT_LIST}', ACTIVE='{ACTIVE_LIST}', MAX_PODS={MAX_PODS}")

    server.start()

    try:
        while True:
            time.sleep(86400)  # Sleep for a day
    except KeyboardInterrupt:
        logger.info("Shutting down gRPC server")
        server.stop(0)

if __name__ == "__main__":
    serve()
