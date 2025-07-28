package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"

	pb "github.com/avishay/redis-bull-scaler/externalscaler"
	"github.com/go-redis/redis/v8"
	"google.golang.org/grpc"
)

// server implements the KEDA ExternalScaler gRPC interface
type server struct {
	pb.UnimplementedExternalScalerServer
	redisClient *redis.Client
}

// getEnv fetches a required environment variable and fails fast if missing
func getEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		log.Fatalf("Missing required env var: %s", key)
	}
	return val
}

// getMetadataValue extracts and validates metadata from ScaledObjectRef
func getMetadataValue(metadata map[string]string, key string) (string, error) {
	value, exists := metadata[key]
	if !exists || value == "" {
		return "", fmt.Errorf("required metadata %s is missing or empty", key)
	}
	return value, nil
}

// validatePortNumber validates that a string represents a valid port number
func validatePortNumber(portStr string) error {
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return fmt.Errorf("port must be a valid number, got: %s", portStr)
	}
	if port <= 0 || port > 65535 {
		return fmt.Errorf("port must be between 1 and 65535, got: %d", port)
	}
	return nil
}

// NewServer initializes the scaler server with Redis connection
func NewServer() *server {
	redisHost := getEnv("REDIS_HOST")
	redisPort := getEnv("REDIS_PORT")

	// Validate port number
	if err := validatePortNumber(redisPort); err != nil {
		log.Fatalf("Invalid REDIS_PORT: %v", err)
	}

	rdb := redis.NewClient(&redis.Options{
		Addr: fmt.Sprintf("%s:%s", redisHost, redisPort),
	})

	// Test Redis connection
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}

	log.Printf("Connected to Redis at %s:%s", redisHost, redisPort)
	log.Printf("External scaler ready - queue configuration will come from ScaledJob metadata")

	return &server{
		redisClient: rdb,
	}
}

// IsActive returns true if there is at least one item in either wait or active list
func (s *server) IsActive(ctx context.Context, req *pb.ScaledObjectRef) (*pb.IsActiveResponse, error) {
	log.Printf("[IsActive] Called for ScaledObject: %s/%s", req.Namespace, req.Name)

	waitList, err := getMetadataValue(req.ScalerMetadata, "waitList")
	if err != nil {
		log.Printf("[IsActive] Error getting waitList: %v", err)
		return &pb.IsActiveResponse{Result: false}, err
	}

	activeList, err := getMetadataValue(req.ScalerMetadata, "activeList")
	if err != nil {
		log.Printf("[IsActive] Error getting activeList: %v", err)
		return &pb.IsActiveResponse{Result: false}, err
	}

	log.Printf("[IsActive] Using queues: wait='%s', active='%s'", waitList, activeList)

	waitLen, err := s.redisClient.LLen(ctx, waitList).Result()
	if err != nil {
		log.Printf("[IsActive] Error getting length of wait list '%s': %v", waitList, err)
		return &pb.IsActiveResponse{Result: false}, err
	}

	activeLen, err := s.redisClient.LLen(ctx, activeList).Result()
	if err != nil {
		log.Printf("[IsActive] Error getting length of active list '%s': %v", activeList, err)
		return &pb.IsActiveResponse{Result: false}, err
	}

	result := (waitLen + activeLen) > 0
	log.Printf("[IsActive] wait=%d, active=%d, total=%d, result=%v", waitLen, activeLen, waitLen+activeLen, result)
	return &pb.IsActiveResponse{Result: result}, nil
}

// GetMetricSpec returns the metric name and target value for scaling
func (s *server) GetMetricSpec(ctx context.Context, req *pb.ScaledObjectRef) (*pb.GetMetricSpecResponse, error) {
	log.Printf("[GetMetricSpec] Called for ScaledObject: %s/%s", req.Namespace, req.Name)

	spec := &pb.MetricSpec{
		MetricName: "bull_queue_length",
		TargetSize: 1,
	}
	log.Printf("[GetMetricSpec] Returning spec: metricName=%s, targetSize=%d", spec.MetricName, spec.TargetSize)
	return &pb.GetMetricSpecResponse{
		MetricSpecs: []*pb.MetricSpec{spec},
	}, nil
}

// GetMetrics returns the current metric value: total jobs in wait+active, capped at maxPods
func (s *server) GetMetrics(ctx context.Context, req *pb.GetMetricsRequest) (*pb.GetMetricsResponse, error) {
	log.Printf("[GetMetrics] Called for ScaledObject: %s/%s", req.ScaledObjectRef.Namespace, req.ScaledObjectRef.Name)

	waitList, err := getMetadataValue(req.ScaledObjectRef.ScalerMetadata, "waitList")
	if err != nil {
		log.Printf("[GetMetrics] Error getting waitList: %v", err)
		return &pb.GetMetricsResponse{}, err
	}

	activeList, err := getMetadataValue(req.ScaledObjectRef.ScalerMetadata, "activeList")
	if err != nil {
		log.Printf("[GetMetrics] Error getting activeList: %v", err)
		return &pb.GetMetricsResponse{}, err
	}

	maxPodsStr, err := getMetadataValue(req.ScaledObjectRef.ScalerMetadata, "maxPods")
	if err != nil {
		log.Printf("[GetMetrics] Error getting maxPods: %v", err)
		return &pb.GetMetricsResponse{}, err
	}

	maxPods, err := strconv.ParseInt(maxPodsStr, 10, 64)
	if err != nil || maxPods <= 0 {
		log.Printf("[GetMetrics] Invalid maxPods value: %s (must be a positive integer)", maxPodsStr)
		return &pb.GetMetricsResponse{}, fmt.Errorf("maxPods must be a positive integer, got: %s", maxPodsStr)
	}

	log.Printf("[GetMetrics] Using queues: wait='%s', active='%s', maxPods=%d", waitList, activeList, maxPods)

	waitLen, err := s.redisClient.LLen(ctx, waitList).Result()
	if err != nil {
		log.Printf("[GetMetrics] Error getting length of wait list '%s': %v", waitList, err)
		return &pb.GetMetricsResponse{}, err
	}

	activeLen, err := s.redisClient.LLen(ctx, activeList).Result()
	if err != nil {
		log.Printf("[GetMetrics] Error getting length of active list '%s': %v", activeList, err)
		return &pb.GetMetricsResponse{}, err
	}

	total := waitLen + activeLen
	metricValue := total
	if metricValue > maxPods {
		metricValue = maxPods
	}

	log.Printf("[GetMetrics] wait=%d, active=%d, total=%d, capped=%d", waitLen, activeLen, total, metricValue)
	return &pb.GetMetricsResponse{
		MetricValues: []*pb.MetricValue{
			{MetricName: "bull_queue_length", MetricValue: metricValue},
		},
	}, nil
}

func main() {
	port := 8080
	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	grpcServer := grpc.NewServer()
	pb.RegisterExternalScalerServer(grpcServer, NewServer())
	log.Printf("Starting gRPC server on :%d", port)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}
