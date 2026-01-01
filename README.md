# Reddit MCP Server (Docker)

Dockerized MCP server providing Reddit API tools for Claude Code and other MCP clients.

## Tools

- **reddit_search** - Search Reddit posts
- **reddit_post** - Get post with comments
- **reddit_trending** - Get trending posts from subreddit

## Quick Start

### Using pre-built image from GHCR

```bash
docker pull ghcr.io/zewelor/reddit_mcp:main
```

Add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "reddit": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "ghcr.io/zewelor/reddit_mcp:main"]
    }
  }
}
```

### Build locally

```bash
docker build -t reddit-mcp .
```

Or with docker compose:

```bash
docker compose build
```

## Usage with Claude Code

Add to your `.mcp.json`:

```json
{
  "mcpServers": {
    "reddit": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "reddit-mcp"]
    }
  }
}
```

## Development

Run directly:

```bash
docker run -i --rm reddit-mcp
```

Test with manual JSON-RPC:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | docker run -i --rm reddit-mcp
```

## License

MIT
