# Claude Code Instructions

## Version Checking Rule

**IMPORTANT**: Before using any external dependency (GitHub Action, library, gem, Docker image, etc.), always check for the latest version using Context7:

1. Use `resolve-library-id` to find the library
2. Use `query-docs` to check current version and usage examples

Example for GitHub Actions:
```
resolve-library-id("actions/checkout", "latest version")
query-docs("/actions/checkout", "latest version usage")
```

## Project Overview

Reddit MCP Server - a Dockerized MCP server providing Reddit API tools for Claude Code and other MCP clients.

## Key Files

- `server.rb` - Main MCP server implementation (Ruby)
- `Dockerfile` - Docker image definition
- `docker-compose.yml` - Docker Compose configuration
- `.github/workflows/docker-publish.yml` - CI/CD workflow

## Testing

Test the MCP server locally:
```bash
docker build -t reddit-mcp .
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | docker run -i --rm reddit-mcp
```

## Available Tools

- `reddit_search` - Search Reddit posts
- `reddit_post` - Get post with comments
- `reddit_trending` - Get trending posts from subreddit
