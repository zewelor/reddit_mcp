FROM ruby:3.4-alpine

# OCI Labels
LABEL org.opencontainers.image.title="Reddit MCP Server"
LABEL org.opencontainers.image.description="Dockerized Reddit API MCP Server for Claude Code"
LABEL org.opencontainers.image.source="https://github.com/zewelor/reddit_mcp"
LABEL org.opencontainers.image.licenses="MIT"

# Install minimal dependencies and remove cache
RUN apk add --no-cache ca-certificates \
    && rm -rf /var/cache/apk/*

# Create non-root user for security
RUN addgroup -g 1000 -S mcp \
    && adduser -u 1000 -S mcp -G mcp -h /app -s /sbin/nologin

WORKDIR /app

# Copy server file with correct ownership
COPY --chown=mcp:mcp server.rb .

# Make executable
RUN chmod +x server.rb

# Switch to non-root user
USER mcp

# MCP servers communicate via stdin/stdout
ENTRYPOINT ["ruby", "server.rb"]
