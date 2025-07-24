# --- Build Stage ---
# Use a compatible Go version for the build
FROM golang:1.24.5-alpine AS build

# Set the working directory inside the container
WORKDIR /app

# Copy Go module files and download dependencies.
# This layer is cached as long as go.mod and go.sum don't change.
COPY go.mod ./
RUN go mod download

# Copy the rest of the source code into the working directory
COPY . .

# Install protoc compiler and Go codegen plugins
RUN apk add --no-cache protobuf git

RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
RUN go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

ENV PATH="${PATH}:$(go env GOPATH)/bin"

# Generate gRPC/protobuf code from externalscaler.proto
RUN protoc --go_out=. --go-grpc_out=. \
  --go_opt=paths=source_relative \
  --go-grpc_opt=paths=source_relative \
  externalscaler/externalscaler.proto

# Tidy modules and build the application.
# The -o flag specifies the output file name. We place it in the root
# of the builder image for easy access from the final stage.
RUN go mod tidy
RUN go build -o /redis-bull-scaler .

# --- Final Stage ---
# Use a minimal base image for a small final image size
FROM alpine:latest

# Set the working directory for the final image
WORKDIR /app

# Copy the built binary from the 'build' stage
COPY --from=build /redis-bull-scaler .

# Set the command to run when the container starts
ENTRYPOINT ["./redis-bull-scaler"]
