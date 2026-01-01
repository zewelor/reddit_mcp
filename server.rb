#!/usr/bin/env ruby
# frozen_string_literal: true

# Reddit MCP Server
# Provides tools for searching and fetching Reddit content

require "json"
require "net/http"
require "uri"

USER_AGENT = "RedditMCP/1.0 (MCP Server)"

# Simple MCP Server implementation
class RedditMCPServer
  def initialize
    @tools = {
      "reddit_search" => {
        name: "reddit_search",
        description: "Search Reddit for posts. Returns titles, scores, and content previews.",
        inputSchema: {
          type: "object",
          properties: {
            query: { type: "string", description: "Search query" },
            subreddit: { type: "string", description: "Subreddit to search in (optional, omit for all)" },
            sort: { type: "string", enum: %w[relevance hot top new], default: "relevance" },
            time: { type: "string", enum: %w[hour day week month year all], default: "all" },
            limit: { type: "integer", default: 10, maximum: 25 }
          },
          required: ["query"]
        }
      },
      "reddit_post" => {
        name: "reddit_post",
        description: "Get a Reddit post with its top comments. Use this to understand what people are saying.",
        inputSchema: {
          type: "object",
          properties: {
            post_id: { type: "string", description: "Reddit post ID (e.g., '1abc123')" },
            comment_limit: { type: "integer", default: 15, maximum: 50 }
          },
          required: ["post_id"]
        }
      },
      "reddit_trending" => {
        name: "reddit_trending",
        description: "Get trending/top posts from a subreddit. Good for understanding what's popular.",
        inputSchema: {
          type: "object",
          properties: {
            subreddit: { type: "string", description: "Subreddit name (e.g., 'selfhosted')" },
            time: { type: "string", enum: %w[hour day week month year all], default: "week" },
            limit: { type: "integer", default: 10, maximum: 25 }
          },
          required: ["subreddit"]
        }
      }
    }
  end

  def run
    $stderr.puts "Reddit MCP Server started"
    $stdout.sync = true

    loop do
      line = $stdin.gets
      break unless line

      begin
        request = JSON.parse(line)
        response = handle_request(request)
        puts JSON.generate(response)
      rescue JSON::ParserError => e
        $stderr.puts "JSON parse error: #{e.message}"
      rescue => e
        $stderr.puts "Error: #{e.message}"
        $stderr.puts e.backtrace.first(5).join("\n")
      end
    end
  end

  private

  def handle_request(request)
    id = request["id"]
    method = request["method"]
    params = request["params"] || {}

    result = case method
             when "initialize"
               handle_initialize(params)
             when "tools/list"
               handle_tools_list
             when "tools/call"
               handle_tool_call(params)
             when "notifications/initialized"
               return nil # No response needed
             else
               { error: { code: -32601, message: "Method not found: #{method}" } }
             end

    return nil unless result

    {
      jsonrpc: "2.0",
      id: id,
      result: result
    }
  end

  def handle_initialize(_params)
    {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "reddit-mcp", version: "1.0.0" }
    }
  end

  def handle_tools_list
    { tools: @tools.values }
  end

  def handle_tool_call(params)
    tool_name = params["name"]
    args = params["arguments"] || {}

    content = case tool_name
              when "reddit_search"
                reddit_search(args)
              when "reddit_post"
                reddit_post(args)
              when "reddit_trending"
                reddit_trending(args)
              else
                "Unknown tool: #{tool_name}"
              end

    { content: [{ type: "text", text: content }] }
  end

  # === Reddit API Methods ===

  def reddit_search(args)
    query = args["query"]
    subreddit = args["subreddit"]
    sort = args["sort"] || "relevance"
    time = args["time"] || "all"
    limit = [args["limit"] || 10, 25].min

    if subreddit
      sub = subreddit.sub(/^r\//, "")
      url = "https://www.reddit.com/r/#{sub}/search.json?q=#{encode(query)}&restrict_sr=1&sort=#{sort}&t=#{time}&limit=#{limit}"
      header = "# Search results for \"#{query}\" in r/#{sub}\n\n"
    else
      url = "https://www.reddit.com/search.json?q=#{encode(query)}&sort=#{sort}&t=#{time}&limit=#{limit}"
      header = "# Search results for \"#{query}\" (all Reddit)\n\n"
    end

    data = http_get(url)
    return "Error: Could not fetch search results" unless data

    posts = data.dig("data", "children") || []
    return "No results found for \"#{query}\"" if posts.empty?

    output = header
    posts.each_with_index do |post, idx|
      p = post["data"]
      output << format_post_preview(p, idx + 1)
    end

    output << "\n---\nUse `reddit_post` with a post_id to see full content and comments."
    output
  end

  def reddit_post(args)
    post_id = args["post_id"].to_s.sub(/^t3_/, "")
    comment_limit = [args["comment_limit"] || 15, 50].min

    # First, get post info to find permalink
    url = "https://www.reddit.com/comments/#{post_id}.json?limit=#{comment_limit}&depth=2&sort=top"
    data = http_get(url)
    return "Error: Could not fetch post #{post_id}" unless data
    return "Error: Post not found" unless data.is_a?(Array) && data.length >= 2

    post_data = data[0].dig("data", "children", 0, "data")
    comments_data = data[1].dig("data", "children") || []

    return "Error: Post data not found" unless post_data

    output = format_full_post(post_data)
    output << "\n## Top Comments\n\n"

    if comments_data.empty?
      output << "_No comments yet_\n"
    else
      comments_data.each do |comment|
        c = comment["data"]
        next unless c && c["body"] # Skip "more" placeholders
        output << format_comment(c)
      end
    end

    output
  end

  def reddit_trending(args)
    subreddit = args["subreddit"].sub(/^r\//, "")
    time = args["time"] || "week"
    limit = [args["limit"] || 10, 25].min

    url = "https://www.reddit.com/r/#{subreddit}/top.json?t=#{time}&limit=#{limit}"
    data = http_get(url)
    return "Error: Could not fetch r/#{subreddit}" unless data

    posts = data.dig("data", "children") || []
    return "No posts found in r/#{subreddit}" if posts.empty?

    output = "# Trending in r/#{subreddit} (top #{time})\n\n"
    posts.each_with_index do |post, idx|
      p = post["data"]
      output << format_post_preview(p, idx + 1)
    end

    output << "\n---\nUse `reddit_post` with a post_id to see full content and comments."
    output
  end

  # === Formatting ===

  def format_post_preview(p, num)
    <<~POST
      ### #{num}. #{p['title']}
      **r/#{p['subreddit']}** | #{p['score']} pts | #{p['num_comments']} comments | id: `#{p['id']}`
      #{preview_text(p['selftext'], 200)}

    POST
  end

  def format_full_post(p)
    output = <<~POST
      # #{p['title']}

      **Subreddit:** r/#{p['subreddit']} | **Score:** #{p['score']} | **Comments:** #{p['num_comments']}
      **Author:** u/#{p['author']} | **Posted:** #{time_ago(p['created_utc'])}

    POST

    if p["selftext"] && !p["selftext"].empty?
      text = p["selftext"]
      if text.length > 2000
        output << "## Content (truncated)\n\n#{text[0..2000]}...\n\n"
      else
        output << "## Content\n\n#{text}\n\n"
      end
    elsif p["url"] && !p["url"].include?("reddit.com")
      output << "**Link:** #{p['url']}\n\n"
    end

    output
  end

  def format_comment(c, indent = 0)
    prefix = "  " * indent
    body = c["body"].to_s.gsub(/\n{3,}/, "\n\n")
    body = body[0..800] + "..." if body.length > 800

    output = "#{prefix}**u/#{c['author']}** (#{c['score']} pts):\n"
    body.lines.each { |line| output << "#{prefix}> #{line}" }
    output << "\n\n"

    # Include top reply if exists (replies can be "" when empty)
    if c["replies"].is_a?(Hash)
      replies = c.dig("replies", "data", "children")
      if replies&.first
        reply = replies.first["data"]
        if reply && reply["body"]
          output << format_comment(reply, indent + 1)
        end
      end
    end

    output
  end

  def preview_text(text, max_len)
    return "" if text.nil? || text.empty?
    clean = text.gsub(/\s+/, " ").strip
    return "" if clean.empty?
    truncated = clean.length > max_len ? clean[0..max_len] + "..." : clean
    "> #{truncated}\n"
  end

  def time_ago(utc)
    return "unknown" unless utc
    diff = Time.now.to_i - utc.to_i
    case diff
    when 0..59 then "just now"
    when 60..3599 then "#{diff / 60}m ago"
    when 3600..86399 then "#{diff / 3600}h ago"
    when 86400..2591999 then "#{diff / 86400}d ago"
    else "#{diff / 2592000}mo ago"
    end
  end

  # === HTTP ===

  def http_get(url, retries: 3)
    encoded_url = URI::DEFAULT_PARSER.escape(url)
    uri = URI(encoded_url)

    attempt = 0
    loop do
      begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT

        response = http.request(request)

        case response.code.to_i
        when 200
          return JSON.parse(response.body)
        when 429, 500, 502, 503, 504
          raise "HTTP #{response.code}"
        else
          $stderr.puts "HTTP Error: #{response.code}"
          return nil
        end
      rescue => e
        attempt += 1
        if attempt > retries
          $stderr.puts "Failed after #{retries} retries: #{e.message}"
          return nil
        end
        sleep(2 ** attempt)
      end
    end
  end

  def encode(str)
    URI.encode_www_form_component(str)
  end
end

# Run the server
RedditMCPServer.new.run if __FILE__ == $PROGRAM_NAME
