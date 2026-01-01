FROM ruby:3.4-alpine

LABEL maintainer="Reddit MCP Server"
LABEL description="Dockerized Reddit API MCP Server"

# Install minimal dependencies
RUN apk add --no-cache ca-certificates

WORKDIR /app

# Copy server file
COPY server.rb .

# Make executable
RUN chmod +x server.rb

# MCP servers communicate via stdin/stdout
ENTRYPOINT ["ruby", "server.rb"]
