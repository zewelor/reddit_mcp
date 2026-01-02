#!/usr/bin/env ruby
# frozen_string_literal: true

# Reddit MCP Server
# Provides tools for searching and fetching Reddit content

require "json"
require "net/http"
require "uri"
require "mcp"

DEFAULT_USER_AGENT = "RedditMCP/1.0 (MCP Server)"
USER_AGENT = ENV.fetch("REDDIT_MCP_USER_AGENT", DEFAULT_USER_AGENT)

SEARCH_SORTS = %w[relevance hot top new].freeze
SEARCH_TIMES = %w[hour day week month year all].freeze
TRENDING_TIMES = %w[hour day week month year all].freeze
OUTPUT_FORMATS = %w[compact full].freeze

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
  # Post preview for search/trending results
  def format_post_preview(p, num, format: "compact")
    if format == "compact"
      format_post_preview_compact(p, num)
    else
      format_post_preview_full(p, num)
    end
  end

  def format_post_preview_compact(p, num)
    preview = preview_text_compact(p["selftext"], 150)
    result = "#{num}. **#{p['title']}** [#{p['id']}] #{p['score']}p #{p['num_comments']}c"
    result << "\n   #{preview}" unless preview.empty?
    result << "\n\n"
    result
  end

  def format_post_preview_full(p, num)
    <<~POST
      ### #{num}. #{p['title']}
      **r/#{p['subreddit']}** | #{p['score']} pts | #{p['num_comments']} comments | id: `#{p['id']}`
      #{preview_text(p['selftext'], 200)}

    POST
  end

  # Full post formatting
  def format_full_post(p, format: "compact")
    if format == "compact"
      format_full_post_compact(p)
    else
      format_full_post_full(p)
    end
  end

  def format_full_post_compact(p)
    output = "## #{p['title']}\nr/#{p['subreddit']} | #{p['score']}p #{p['num_comments']}c\n\n"

    if p["selftext"] && !p["selftext"].empty?
      text = p["selftext"]
      text = text[0..2000] + "..." if text.length > 2000
      output << "#{text}\n\n"
    elsif p["url"] && !p["url"].include?("reddit.com")
      output << "Link: #{p['url']}\n\n"
    end

    output
  end

  def format_full_post_full(p)
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

  # Comment tree formatting
  def format_comment_tree(comments, max_depth, max_count, format: "compact", indent: 0)
    output = +""
    count = 0

    comments.each do |comment|
      break if count >= max_count
      c = comment["data"]
      next unless c && c["body"]

      output << format_comment_body(c, indent, format: format)
      count += 1

      next unless max_depth > 1
      replies = c["replies"]
      next unless replies.is_a?(Hash)
      children = replies.dig("data", "children")
      next unless children.is_a?(Array) && !children.empty?

      child_output, child_count = format_comment_tree(children, max_depth - 1, max_count - count, format: format, indent: indent + 1)
      output << child_output
      count += child_count
    end

    [output, count]
  end

  def format_comment_body(c, indent, format: "compact")
    prefix = "  " * indent
    body = c["body"].to_s.gsub(/\n{3,}/, "\n\n")
    body = body[0..800] + "..." if body.length > 800

    if format == "compact"
      output = "#{prefix}[#{c['score']}p] #{body.lines.first&.strip || ''}"
      if body.lines.count > 1
        body.lines.drop(1).each { |line| output << "\n#{prefix}#{line.rstrip}" }
      end
      output << "\n\n"
    else
      output = "#{prefix}**u/#{c['author']}** (#{c['score']} pts):\n"
      body.lines.each { |line| output << "#{prefix}> #{line}" }
      output << "\n\n"
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

  def preview_text_compact(text, max_len)
    return "" if text.nil? || text.empty?
    clean = text.gsub(/\s+/, " ").strip
    return "" if clean.empty?
    clean.length > max_len ? clean[0..max_len] + "..." : clean
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
  attr_reader :client, :formatter

  def initialize(client:, formatter:)
    @client = client
    @formatter = formatter
  end

  def search(query:, subreddit:, sort:, time:, limit:, format: "compact")
    if subreddit
      url = "https://www.reddit.com/r/#{subreddit}/search.json?q=#{encode(query)}&restrict_sr=1&sort=#{sort}&t=#{time}&limit=#{limit}"
    else
      url = "https://www.reddit.com/search.json?q=#{encode(query)}&sort=#{sort}&t=#{time}&limit=#{limit}"
    end

    data = @client.get_json(url)
    return "Error: Could not fetch search results" unless data

    posts = data.dig("data", "children") || []
    return "No results found for \"#{@formatter.display_text(query)}\"" if posts.empty?

    # Header
    query_display = @formatter.display_text(query)
    if format == "compact"
      sub_part = subreddit ? "r/#{subreddit}" : "all"
      output = "## \"#{query_display}\" in #{sub_part}\n\n"
    else
      if subreddit
        output = "# Search results for \"#{query_display}\" in r/#{subreddit}\n\n"
      else
        output = "# Search results for \"#{query_display}\" (all Reddit)\n\n"
      end
    end

    posts.each_with_index do |post, idx|
      p = post["data"]
      output << @formatter.format_post_preview(p, idx + 1, format: format)
    end

    output << "\n---\nUse `reddit_post` with a post_id to see full content and comments." if format == "full"
    output
  end

  def post(post_id:, comment_limit:, comment_depth:, format: "compact")
    url = "https://www.reddit.com/comments/#{post_id}.json?limit=#{comment_limit}&depth=#{comment_depth}&sort=top"
    data = @client.get_json(url)
    return "Error: Could not fetch post #{post_id}" unless data
    return "Error: Post not found" unless data.is_a?(Array) && data.length >= 2

    post_data = data[0].dig("data", "children", 0, "data")
    comments_data = data[1].dig("data", "children") || []

    return "Error: Post data not found" unless post_data

    output = @formatter.format_full_post(post_data, format: format)

    if format == "compact"
      output << "---\n**Comments:**\n\n"
    else
      output << "\n## Top Comments\n\n"
    end

    if comments_data.empty?
      output << "_No comments yet_\n"
    else
      comments_output, count = @formatter.format_comment_tree(comments_data, comment_depth, comment_limit, format: format)
      if comments_output.empty?
        output << "_No comments yet_\n"
      else
        output << comments_output
        output << "\n---\nShowing #{count} comments (depth #{comment_depth}, limit #{comment_limit})." if format == "full"
      end
    end

    output
  end

  def trending(subreddit:, time:, limit:, format: "compact")
    url = "https://www.reddit.com/r/#{subreddit}/top.json?t=#{time}&limit=#{limit}"
    data = @client.get_json(url)
    return "Error: Could not fetch r/#{subreddit}" unless data

    posts = data.dig("data", "children") || []
    return "No posts found in r/#{subreddit}" if posts.empty?

    if format == "compact"
      output = "## r/#{subreddit} top #{time}\n\n"
    else
      output = "# Trending in r/#{subreddit} (top #{time})\n\n"
    end

    posts.each_with_index do |post, idx|
      p = post["data"]
      output << @formatter.format_post_preview(p, idx + 1, format: format)
    end

    output << "\n---\nUse `reddit_post` with a post_id to see full content and comments." if format == "full"
    output
  end

  private

  def encode(str)
    URI.encode_www_form_component(str)
  end
end

# MCP Tool definitions using the official SDK

class RedditSearchTool < MCP::Tool
  description "Search Reddit for posts. Returns titles, scores, and content previews."

  input_schema(
    properties: {
      query: { type: "string", description: "Search query" },
      subreddit: { type: "string", description: "Subreddit to search in (optional, omit for all)" },
      sort: { type: "string", enum: SEARCH_SORTS, default: "relevance", description: "Sort order" },
      time: { type: "string", enum: SEARCH_TIMES, default: "all", description: "Time filter" },
      limit: { type: "integer", default: 10, maximum: MAX_SEARCH_LIMIT, description: "Number of results" },
      format: { type: "string", enum: OUTPUT_FORMATS, default: "compact", description: "Output format: compact (p=points, c=comments) or full (verbose with authors, dates)" }
    },
    required: ["query"]
  )

  def self.call(query:, subreddit: nil, sort: "relevance", time: "all", limit: 10, format: "compact", server_context:)
    service = server_context[:service]

    # Validate and normalize inputs
    query = query.to_s.strip
    return error_response("query is required") if query.empty?

    if subreddit
      subreddit = normalize_subreddit(subreddit)
      return error_response("subreddit must be a valid name") unless subreddit
    end

    return error_response("sort must be one of: #{SEARCH_SORTS.join(', ')}") unless SEARCH_SORTS.include?(sort)
    return error_response("time must be one of: #{SEARCH_TIMES.join(', ')}") unless SEARCH_TIMES.include?(time)
    format = OUTPUT_FORMATS.include?(format) ? format : "compact"

    limit = limit.to_i.clamp(1, MAX_SEARCH_LIMIT)

    result = service.search(query: query, subreddit: subreddit, sort: sort, time: time, limit: limit, format: format)
    MCP::Tool::Response.new([{ type: "text", text: result }])
  end

  def self.normalize_subreddit(value)
    str = value.to_s.strip
    return nil if str.empty?
    str = str.sub(/^r\//i, "")
    return nil if str.empty?
    return nil unless str.match?(/\A[a-z0-9_]+\z/i)
    str
  end

  def self.error_response(message)
    MCP::Tool::Response.new([{ type: "text", text: "Error: #{message}" }], is_error: true)
  end
end

class RedditPostTool < MCP::Tool
  description "Get a Reddit post with comments. Use comment_limit/comment_depth to fetch more."

  input_schema(
    properties: {
      post_id: { type: "string", description: "Reddit post ID (e.g., '1abc123')" },
      comment_limit: { type: "integer", default: 15, maximum: MAX_COMMENT_LIMIT, description: "Max comments" },
      comment_depth: { type: "integer", default: 2, maximum: MAX_COMMENT_DEPTH, description: "Reply depth" },
      format: { type: "string", enum: OUTPUT_FORMATS, default: "compact", description: "Output format: compact (p=points, c=comments) or full (verbose with authors, dates)" }
    },
    required: ["post_id"]
  )

  def self.call(post_id:, comment_limit: 15, comment_depth: 2, format: "compact", server_context:)
    service = server_context[:service]

    # Validate and normalize inputs
    post_id = normalize_post_id(post_id)
    return error_response("post_id is required and must be valid") unless post_id

    comment_limit = comment_limit.to_i.clamp(1, MAX_COMMENT_LIMIT)
    comment_depth = comment_depth.to_i.clamp(1, MAX_COMMENT_DEPTH)
    format = OUTPUT_FORMATS.include?(format) ? format : "compact"

    result = service.post(post_id: post_id, comment_limit: comment_limit, comment_depth: comment_depth, format: format)
    MCP::Tool::Response.new([{ type: "text", text: result }])
  end

  def self.normalize_post_id(value)
    str = value.to_s.strip
    return nil if str.empty?
    str = str.sub(/^t3_/i, "")
    return nil unless str.match?(/\A[a-z0-9]+\z/i)
    str
  end

  def self.error_response(message)
    MCP::Tool::Response.new([{ type: "text", text: "Error: #{message}" }], is_error: true)
  end
end

class RedditTrendingTool < MCP::Tool
  description "Get trending/top posts from a subreddit. Good for understanding what's popular."

  input_schema(
    properties: {
      subreddit: { type: "string", description: "Subreddit name (e.g., 'selfhosted')" },
      time: { type: "string", enum: TRENDING_TIMES, default: "week", description: "Time period" },
      limit: { type: "integer", default: 10, maximum: MAX_TRENDING_LIMIT, description: "Number of posts" },
      format: { type: "string", enum: OUTPUT_FORMATS, default: "compact", description: "Output format: compact (p=points, c=comments) or full (verbose with authors, dates)" }
    },
    required: ["subreddit"]
  )

  def self.call(subreddit:, time: "week", limit: 10, format: "compact", server_context:)
    service = server_context[:service]

    # Validate and normalize inputs
    subreddit = normalize_subreddit(subreddit)
    return error_response("subreddit is required and must be valid") unless subreddit

    return error_response("time must be one of: #{TRENDING_TIMES.join(', ')}") unless TRENDING_TIMES.include?(time)
    format = OUTPUT_FORMATS.include?(format) ? format : "compact"

    limit = limit.to_i.clamp(1, MAX_TRENDING_LIMIT)

    result = service.trending(subreddit: subreddit, time: time, limit: limit, format: format)
    MCP::Tool::Response.new([{ type: "text", text: result }])
  end

  def self.normalize_subreddit(value)
    str = value.to_s.strip
    return nil if str.empty?
    str = str.sub(/^r\//i, "")
    return nil if str.empty?
    return nil unless str.match?(/\A[a-z0-9_]+\z/i)
    str
  end

  def self.error_response(message)
    MCP::Tool::Response.new([{ type: "text", text: "Error: #{message}" }], is_error: true)
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  $stderr.puts "Reddit MCP Server started"

  client = RedditClient.new(user_agent: USER_AGENT)
  formatter = RedditFormatter.new
  service = RedditService.new(client: client, formatter: formatter)

  server = MCP::Server.new(
    name: "reddit-mcp",
    version: "1.0.0",
    tools: [RedditSearchTool, RedditPostTool, RedditTrendingTool],
    server_context: { service: service }
  )

  transport = MCP::Server::Transports::StdioTransport.new(server)
  transport.open
end
