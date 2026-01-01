#!/usr/bin/env ruby
# frozen_string_literal: true

# Reddit MCP Server
# Provides tools for searching and fetching Reddit content

require "json"
require "net/http"
require "uri"

DEFAULT_USER_AGENT = "RedditMCP/1.0 (MCP Server)"
USER_AGENT = ENV.fetch("REDDIT_MCP_USER_AGENT", DEFAULT_USER_AGENT)

SEARCH_SORTS = %w[relevance hot top new].freeze
SEARCH_TIMES = %w[hour day week month year all].freeze
TRENDING_TIMES = %w[hour day week month year all].freeze

MAX_SEARCH_LIMIT = 25
MAX_TRENDING_LIMIT = 25
MAX_COMMENT_LIMIT = 200
MAX_COMMENT_DEPTH = 5

class RedditClient
  def initialize(user_agent:)
    @user_agent = user_agent
  end

  def get_json(url, retries: 3)
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
        request["User-Agent"] = @user_agent

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
        sleep(2**attempt)
      end
    end
  end
end

class RedditFormatter
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

  def format_comment_tree(comments, max_depth, max_count, indent = 0)
    output = +""
    count = 0

    comments.each do |comment|
      break if count >= max_count
      c = comment["data"]
      next unless c && c["body"]

      output << format_comment_body(c, indent)
      count += 1

      next unless max_depth > 1
      replies = c["replies"]
      next unless replies.is_a?(Hash)
      children = replies.dig("data", "children")
      next unless children.is_a?(Array) && !children.empty?

      child_output, child_count = format_comment_tree(children, max_depth - 1, max_count - count, indent + 1)
      output << child_output
      count += child_count
    end

    [output, count]
  end

  def format_comment_body(c, indent)
    prefix = "  " * indent
    body = c["body"].to_s.gsub(/\n{3,}/, "\n\n")
    body = body[0..800] + "..." if body.length > 800

    output = "#{prefix}**u/#{c['author']}** (#{c['score']} pts):\n"
    body.lines.each { |line| output << "#{prefix}> #{line}" }
    output << "\n\n"
    output
  end

  def preview_text(text, max_len)
    return "" if text.nil? || text.empty?
    clean = text.gsub(/\s+/, " ").strip
    return "" if clean.empty?
    truncated = clean.length > max_len ? clean[0..max_len] + "..." : clean
    "> #{truncated}\n"
  end

  def display_text(text)
    text.to_s.gsub(/\s+/, " ").strip
  end

  def time_ago(utc)
    return "unknown" unless utc
    diff = Time.now.to_i - utc.to_i
    case diff
    when 0..59 then "just now"
    when 60..3599 then "#{diff / 60}m ago"
    when 3600..86399 then "#{diff / 3600}h ago"
    when 86400..2_591_999 then "#{diff / 86_400}d ago"
    else "#{diff / 2_592_000}mo ago"
    end
  end
end

class RedditService
  def initialize(client:, formatter:)
    @client = client
    @formatter = formatter
  end

  def search(query:, subreddit:, sort:, time:, limit:)
    if subreddit
      url = "https://www.reddit.com/r/#{subreddit}/search.json?q=#{encode(query)}&restrict_sr=1&sort=#{sort}&t=#{time}&limit=#{limit}"
      header = "# Search results for \"#{@formatter.display_text(query)}\" in r/#{subreddit}\n\n"
    else
      url = "https://www.reddit.com/search.json?q=#{encode(query)}&sort=#{sort}&t=#{time}&limit=#{limit}"
      header = "# Search results for \"#{@formatter.display_text(query)}\" (all Reddit)\n\n"
    end

    data = @client.get_json(url)
    return "Error: Could not fetch search results" unless data

    posts = data.dig("data", "children") || []
    return "No results found for \"#{@formatter.display_text(query)}\"" if posts.empty?

    output = header
    posts.each_with_index do |post, idx|
      p = post["data"]
      output << @formatter.format_post_preview(p, idx + 1)
    end

    output << "\n---\nUse `reddit_post` with a post_id to see full content and comments."
    output
  end

  def post(post_id:, comment_limit:, comment_depth:)
    url = "https://www.reddit.com/comments/#{post_id}.json?limit=#{comment_limit}&depth=#{comment_depth}&sort=top"
    data = @client.get_json(url)
    return "Error: Could not fetch post #{post_id}" unless data
    return "Error: Post not found" unless data.is_a?(Array) && data.length >= 2

    post_data = data[0].dig("data", "children", 0, "data")
    comments_data = data[1].dig("data", "children") || []

    return "Error: Post data not found" unless post_data

    output = @formatter.format_full_post(post_data)
    output << "\n## Top Comments\n\n"

    if comments_data.empty?
      output << "_No comments yet_\n"
    else
      comments_output, count = @formatter.format_comment_tree(comments_data, comment_depth, comment_limit)
      if comments_output.empty?
        output << "_No comments yet_\n"
      else
        output << comments_output
        output << "\n---\nShowing #{count} comments (depth #{comment_depth}, limit #{comment_limit})."
      end
    end

    output
  end

  def trending(subreddit:, time:, limit:)
    url = "https://www.reddit.com/r/#{subreddit}/top.json?t=#{time}&limit=#{limit}"
    data = @client.get_json(url)
    return "Error: Could not fetch r/#{subreddit}" unless data

    posts = data.dig("data", "children") || []
    return "No posts found in r/#{subreddit}" if posts.empty?

    output = "# Trending in r/#{subreddit} (top #{time})\n\n"
    posts.each_with_index do |post, idx|
      p = post["data"]
      output << @formatter.format_post_preview(p, idx + 1)
    end

    output << "\n---\nUse `reddit_post` with a post_id to see full content and comments."
    output
  end

  private

  def encode(str)
    URI.encode_www_form_component(str)
  end
end

# Simple MCP Server implementation
class RedditMCPServer
  def initialize
    @client = RedditClient.new(user_agent: USER_AGENT)
    @formatter = RedditFormatter.new
    @service = RedditService.new(client: @client, formatter: @formatter)

    @tools = {
      "reddit_search" => {
        name: "reddit_search",
        description: "Search Reddit for posts. Returns titles, scores, and content previews.",
        inputSchema: {
          type: "object",
          properties: {
            query: { type: "string", description: "Search query" },
            subreddit: { type: "string", description: "Subreddit to search in (optional, omit for all)" },
            sort: { type: "string", enum: SEARCH_SORTS, default: "relevance" },
            time: { type: "string", enum: SEARCH_TIMES, default: "all" },
            limit: { type: "integer", default: 10, maximum: MAX_SEARCH_LIMIT }
          },
          required: ["query"]
        }
      },
      "reddit_post" => {
        name: "reddit_post",
        description: "Get a Reddit post with comments. Use comment_limit/comment_depth to fetch more.",
        inputSchema: {
          type: "object",
          properties: {
            post_id: { type: "string", description: "Reddit post ID (e.g., '1abc123')" },
            comment_limit: { type: "integer", default: 15, maximum: MAX_COMMENT_LIMIT },
            comment_depth: { type: "integer", default: 2, maximum: MAX_COMMENT_DEPTH }
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
            time: { type: "string", enum: TRENDING_TIMES, default: "week" },
            limit: { type: "integer", default: 10, maximum: MAX_TRENDING_LIMIT }
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
        puts JSON.generate(response) if response
      rescue JSON::ParserError
        puts JSON.generate(jsonrpc_error(nil, -32700, "Parse error"))
      rescue => e
        $stderr.puts "Error: #{e.message}"
        $stderr.puts e.backtrace.first(5).join("\n")
      end
    end
  end

  private

  def handle_request(request)
    return jsonrpc_error(nil, -32600, "Invalid Request") unless request.is_a?(Hash)

    id = request["id"]
    method = request["method"]
    return jsonrpc_error(id, -32600, "Invalid Request") unless method.is_a?(String)

    params = request["params"]
    params = {} if params.nil?
    return jsonrpc_error(id, -32602, "Params must be an object") unless params.is_a?(Hash)

    case method
    when "initialize"
      jsonrpc_result(id, handle_initialize(params))
    when "tools/list"
      jsonrpc_result(id, handle_tools_list)
    when "tools/call"
      handle_tool_call(id, params)
    when "notifications/initialized"
      nil
    else
      jsonrpc_error(id, -32601, "Method not found: #{method}")
    end
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

  def handle_tool_call(id, params)
    tool_name = params["name"]
    args = params["arguments"] || {}

    return jsonrpc_error(id, -32601, "Tool not found: #{tool_name}") unless @tools.key?(tool_name)
    return jsonrpc_error(id, -32602, "Arguments must be an object") unless args.is_a?(Hash)

    validation = validate_tool_args(tool_name, args)
    return jsonrpc_error(id, -32602, validation[:message]) unless validation[:ok]

    content = case tool_name
              when "reddit_search"
                query = normalize_query(args["query"])
                subreddit = args.key?("subreddit") ? normalize_subreddit(args["subreddit"]) : nil
                sort = args["sort"] || "relevance"
                time = args["time"] || "all"
                limit = parse_int(args["limit"], 10)
                @service.search(query: query, subreddit: subreddit, sort: sort, time: time, limit: limit)
              when "reddit_post"
                post_id = normalize_post_id(args["post_id"])
                comment_limit = parse_int(args["comment_limit"], 15)
                comment_depth = parse_int(args["comment_depth"], 2)
                @service.post(post_id: post_id, comment_limit: comment_limit, comment_depth: comment_depth)
              when "reddit_trending"
                subreddit = normalize_subreddit(args["subreddit"])
                time = args["time"] || "week"
                limit = parse_int(args["limit"], 10)
                @service.trending(subreddit: subreddit, time: time, limit: limit)
              else
                "Unknown tool: #{tool_name}"
              end

    jsonrpc_result(id, { content: [{ type: "text", text: content }] })
  end

  def validate_tool_args(tool_name, args)
    case tool_name
    when "reddit_search"
      return invalid("query is required") unless normalize_query(args["query"])
      if args.key?("subreddit")
        return invalid("subreddit must be a valid name") unless normalize_subreddit(args["subreddit"])
      end
      if args.key?("sort") && !SEARCH_SORTS.include?(args["sort"])
        return invalid("sort must be one of: #{SEARCH_SORTS.join(', ')}")
      end
      if args.key?("time") && !SEARCH_TIMES.include?(args["time"])
        return invalid("time must be one of: #{SEARCH_TIMES.join(', ')}")
      end
      if args.key?("limit") && !valid_int_range?(args["limit"], 1, MAX_SEARCH_LIMIT)
        return invalid("limit must be an integer between 1 and #{MAX_SEARCH_LIMIT}")
      end
    when "reddit_post"
      return invalid("post_id is required") unless normalize_post_id(args["post_id"])
      if args.key?("comment_limit") && !valid_int_range?(args["comment_limit"], 1, MAX_COMMENT_LIMIT)
        return invalid("comment_limit must be an integer between 1 and #{MAX_COMMENT_LIMIT}")
      end
      if args.key?("comment_depth") && !valid_int_range?(args["comment_depth"], 1, MAX_COMMENT_DEPTH)
        return invalid("comment_depth must be an integer between 1 and #{MAX_COMMENT_DEPTH}")
      end
    when "reddit_trending"
      return invalid("subreddit is required") unless normalize_subreddit(args["subreddit"])
      if args.key?("time") && !TRENDING_TIMES.include?(args["time"])
        return invalid("time must be one of: #{TRENDING_TIMES.join(', ')}")
      end
      if args.key?("limit") && !valid_int_range?(args["limit"], 1, MAX_TRENDING_LIMIT)
        return invalid("limit must be an integer between 1 and #{MAX_TRENDING_LIMIT}")
      end
    end

    { ok: true }
  end

  def invalid(message)
    { ok: false, message: message }
  end

  def jsonrpc_result(id, result)
    { jsonrpc: "2.0", id: id, result: result }
  end

  def jsonrpc_error(id, code, message)
    { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
  end

  def normalize_query(value)
    str = value.to_s.strip
    return nil if str.empty?
    str
  end

  def normalize_subreddit(value)
    str = value.to_s.strip
    return nil if str.empty?
    str = str.sub(/^r\//i, "")
    return nil if str.empty?
    return nil unless str.match?(/\A[a-z0-9_]+\z/i)
    str
  end

  def normalize_post_id(value)
    str = value.to_s.strip
    return nil if str.empty?
    str = str.sub(/^t3_/i, "")
    return nil unless str.match?(/\A[a-z0-9]+\z/i)
    str
  end

  def valid_int_range?(value, min, max)
    int = Integer(value)
    int >= min && int <= max
  rescue ArgumentError, TypeError
    false
  end

  def parse_int(value, default)
    return default if value.nil?
    Integer(value)
  rescue ArgumentError, TypeError
    default
  end
end

# Run the server
RedditMCPServer.new.run if __FILE__ == $PROGRAM_NAME
