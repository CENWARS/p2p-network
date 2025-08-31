# Multi-stage build for optimized container size
FROM rust:latest as builder

# Install musl for static linking
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    ca-certificates \
    musl-tools \
    && rustup target add x86_64-unknown-linux-musl \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy the source code
COPY Cargo.toml Cargo.lock ./
COPY src/ ./src/

# Build the application in release mode with musl for static linking
ENV PKG_CONFIG_ALLOW_CROSS=1
ENV OPENSSL_STATIC=true
ENV OPENSSL_DIR=/usr/lib/ssl
RUN cargo build --release --target x86_64-unknown-linux-musl --bin p2p-node

# Runtime stage with minimal dependencies  
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache ca-certificates

# Create app user for security
RUN adduser -D -s /bin/false appuser

# Set working directory
WORKDIR /app

# Copy the built binary
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/p2p-node /app/p2p-node

# Create data directory and set permissions
RUN mkdir -p /app/data && \
    chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Expose the P2P port
EXPOSE 4001

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD netstat -an | grep :4001 > /dev/null; if [ 0 != $? ]; then exit 1; fi;

# Default command
CMD ["./p2p-node", "--config", "/app/config.yaml"]
