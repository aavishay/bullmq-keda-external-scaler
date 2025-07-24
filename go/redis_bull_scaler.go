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
	waitList    string
	activeList  string
	maxPods     int64
}

// getEnv fetches a required environment variable and fails fast if missing
func getEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		log.Fatalf("Missing required env var: %s", key)
	}
	return val
}

// NewServer initializes the scaler server with Redis connection and config
func NewServer() *server {
	redisHost := getEnv("REDIS_HOST")
	redisPort := getEnv("REDIS_PORT")
	waitList := getEnv("WAIT_LIST")
	activeList := getEnv("ACTIVE_LIST")
	maxPodsStr := getEnv("MAX_PODS")
	maxPods, err := strconv.ParseInt(maxPodsStr, 10, 64)
	if err != nil || maxPods <= 0 {
		log.Fatalf("MAX_PODS must be a positive integer")
	}

	rdb := redis.NewClient(&redis.Options{
		Addr: fmt.Sprintf("%s:%s", redisHost, redisPort),
	})

	// Test Redis connection
	if err := rdb.Ping(context.Background()).Err(); err != nil {
		log.Fatalf("Failed to connect to Redis: %v", err)
	}

	log.Printf("Connected to Redis at %s:%s", redisHost, redisPort)
	log.Printf("Queue config: WAIT='%s', ACTIVE='%s', MAX_PODS=%d", waitList, activeList, maxPods)

	return &server{
		redisClient: rdb,
		waitList:    waitList,
		activeList:  activeList,
		maxPods:     maxPods,
	}
}

// IsActive returns true if there is at least one item in either wait or active list
func (s *server) IsActive(ctx context.Context, req *pb.ScaledObjectRef) (*pb.IsActiveResponse, error) {
	waitLen, _ := s.redisClient.LLen(ctx, s.waitList).Result()
	activeLen, _ := s.redisClient.LLen(ctx, s.activeList).Result()
	result := (waitLen + activeLen) > 0
	log.Printf("[IsActive] wait=%d, active=%d, total=%d, result=%v", waitLen, activeLen, waitLen+activeLen, result)
	return &pb.IsActiveResponse{Result: result}, nil
}

// GetMetricSpec returns the metric name and target value for scaling
func (s *server) GetMetricSpec(ctx context.Context, req *pb.ScaledObjectRef) (*pb.GetMetricSpecResponse, error) {
	spec := &pb.MetricSpec{
		MetricName: "bull_queue_length",
		TargetSize: 1,
	}
	log.Printf("[GetMetricSpec] Returning spec: metricName=%s, targetSize=%d", spec.MetricName, spec.TargetSize)
	return &pb.GetMetricSpecResponse{
		MetricSpecs: []*pb.MetricSpec{spec},
	}, nil
}

// GetMetrics returns the current metric value: total jobs in wait+active, capped at MAX_PODS
func (s *server) GetMetrics(ctx context.Context, req *pb.GetMetricsRequest) (*pb.GetMetricsResponse, error) {
	waitLen, _ := s.redisClient.LLen(ctx, s.waitList).Result()
	activeLen, _ := s.redisClient.LLen(ctx, s.activeList).Result()
	total := waitLen + activeLen
	metricValue := total
	if metricValue > s.maxPods {
		metricValue = s.maxPods
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
