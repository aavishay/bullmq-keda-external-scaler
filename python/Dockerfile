FROM python:3.10 as protobuf-builder

# Install protobuf compiler and grpcio-tools
RUN apt-get update && apt-get install -y protobuf-compiler
RUN pip install grpcio-tools==1.60.0

WORKDIR /build

# Copy proto file
COPY externalscaler.proto .

# Generate protobuf files
RUN python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. externalscaler.proto

FROM python:3.10-slim

# Set work directory
WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy generated protobuf files from builder stage
COPY --from=protobuf-builder /build/externalscaler_pb2.py .
COPY --from=protobuf-builder /build/externalscaler_pb2_grpc.py .

# Copy scaler code
COPY redis_bull_scaler.py .

# Expose gRPC port
EXPOSE 8080

# Run the gRPC server
CMD ["python", "redis_bull_scaler.py"]
