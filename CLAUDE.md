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
- `Dockerfile` - Multi-stage Docker image definition
- `compose.yml` - Docker Compose configuration
- `Gemfile` / `Gemfile.lock` - Ruby dependencies
- `.github/workflows/docker-publish.yml` - CI/CD workflow

## Development Environment

**IMPORTANT**: Ruby is NOT installed locally. All Ruby/Bundler commands must be run through Docker.

### Running Ruby commands via Docker Compose

The `dev` service uses the `dev` stage from Dockerfile (has build tools for native extensions).

```bash
# Build dev image (once, or after Dockerfile changes)
docker compose build dev

# Install/update gems (generate Gemfile.lock)
docker compose run --rm dev bundle install

# Run tests
docker compose run --rm dev bundle exec ruby -Itest test/server_test.rb

# Run any Ruby command
docker compose run --rm dev ruby -e "puts RUBY_VERSION"
```

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
