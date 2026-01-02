#!/usr/bin/env ruby
# frozen_string_literal: true

# Reddit MCP Server
# Provides tools for searching and fetching Reddit content

require "json"
require "net/http"
require "uri"
require "mcp"

require_relative "formatters/text"
require_relative "formatters/json"

DEFAULT_USER_AGENT = "RedditMCP/1.0 (MCP Server)"
USER_AGENT = ENV.fetch("REDDIT_MCP_USER_AGENT", DEFAULT_USER_AGENT)

SEARCH_SORTS = %w[relevance hot top new].freeze
TIME_FILTERS = %w[hour day week month year all].freeze

# Output type: json or text (markdown)
OUTPUT_TYPES = %w[json text].freeze
DEFAULT_OUTPUT = ENV.fetch("REDDIT_MCP_OUTPUT", "text").then { |t| OUTPUT_TYPES.include?(t) ? t : "text" }

# Verbosity levels:
# - minimal: text only, no scores/authors/dates
# - compact: with scores (p=points, c=comments), no authors/dates
# - full: all fields including authors, dates
VERBOSITY_LEVELS = %w[minimal compact full].freeze
DEFAULT_VERBOSITY = ENV.fetch("REDDIT_MCP_VERBOSITY", "compact").then { |v| VERBOSITY_LEVELS.include?(v) ? v : "compact" }

MAX_SEARCH_LIMIT = 25
MAX_TRENDING_LIMIT = 25
MAX_COMMENT_LIMIT = 200
MAX_COMMENT_DEPTH = 5

VERBOSITY_SCHEMA = {
  type: "string",
  enum: VERBOSITY_LEVELS,
  default: "compact",
  description: "minimal (text only), compact (p=points, c=comments), full (authors, dates)"
}.freeze

# Shared helpers for MCP tools
module RedditToolHelpers
  SUBREDDIT_PATTERN = /\A[a-z0-9_]+\z/i
  POST_ID_PATTERN = /\A[a-z0-9]+\z/i

  def normalize_subreddit(value)
    str = value.to_s.strip
    return nil if str.empty?
    str = str.sub(/^r\//i, "")
    return nil if str.empty?
    return nil unless str.match?(SUBREDDIT_PATTERN)
    str
  end

  def normalize_post_id(value)
    str = value.to_s.strip
    return nil if str.empty?
    str = str.sub(/^t3_/i, "")
    return nil unless str.match?(POST_ID_PATTERN)
    str
  end

  def normalize_verbosity(value)
    VERBOSITY_LEVELS.include?(value) ? value : DEFAULT_VERBOSITY
  end

  def error_response(message)
    MCP::Tool::Response.new([{ type: "text", text: "Error: #{message}" }], is_error: true)
  end
end

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

class RedditService
  attr_reader :client

  def initialize(client:, formatter: nil)
    @client = client
    @text_formatter = TextFormatter.new
    @json_formatter = JsonFormatter.new
  end

  def formatter_for(output_type)
    output_type == "json" ? @json_formatter : @text_formatter
  end

  def search(query:, subreddit:, sort:, time:, limit:, output: DEFAULT_OUTPUT, verbosity: DEFAULT_VERBOSITY)
    fmt = formatter_for(output)

    if subreddit
      url = "https://www.reddit.com/r/#{subreddit}/search.json?q=#{encode(query)}&restrict_sr=1&sort=#{sort}&t=#{time}&limit=#{limit}"
    else
      url = "https://www.reddit.com/search.json?q=#{encode(query)}&sort=#{sort}&t=#{time}&limit=#{limit}"
    end

    data = @client.get_json(url)
    return fmt.error("fetch_failed") unless data

    posts = data.dig("data", "children") || []
    return fmt.empty_result if posts.empty?

    query_display = query.to_s.gsub(/\s+/, " ").strip
    fmt.format_search(posts, query: query_display, subreddit: subreddit, verbosity: verbosity)
  end

  def post(post_id:, comment_limit:, comment_depth:, output: DEFAULT_OUTPUT, verbosity: DEFAULT_VERBOSITY)
    fmt = formatter_for(output)

    url = "https://www.reddit.com/comments/#{post_id}.json?limit=#{comment_limit}&depth=#{comment_depth}&sort=top"
    data = @client.get_json(url)
    return fmt.error("fetch_failed") unless data
    return fmt.error("not_found") unless data.is_a?(Array) && data.length >= 2

    post_data = data[0].dig("data", "children", 0, "data")
    comments_data = data[1].dig("data", "children") || []

    return fmt.error("post_data_missing") unless post_data

    fmt.format_post(post_data, comments_data, comment_depth: comment_depth, comment_limit: comment_limit, verbosity: verbosity)
  end

  def trending(subreddit:, time:, limit:, output: DEFAULT_OUTPUT, verbosity: DEFAULT_VERBOSITY)
    fmt = formatter_for(output)

    url = "https://www.reddit.com/r/#{subreddit}/top.json?t=#{time}&limit=#{limit}"
    data = @client.get_json(url)
    return fmt.error("fetch_failed") unless data

    posts = data.dig("data", "children") || []
    return fmt.empty_result if posts.empty?

    fmt.format_trending(posts, subreddit: subreddit, time: time, verbosity: verbosity)
  end

  private

  def encode(str)
    URI.encode_www_form_component(str)
  end
end

# MCP Tool definitions using the official SDK

class RedditSearchTool < MCP::Tool
  extend RedditToolHelpers
  description "Search Reddit for posts. Returns titles, scores, and content previews."

  input_schema(
    properties: {
      query: { type: "string", description: "Search query" },
      subreddit: { type: "string", description: "Subreddit to search in (optional, omit for all)" },
      sort: { type: "string", enum: SEARCH_SORTS, default: "relevance", description: "Sort order" },
      time: { type: "string", enum: TIME_FILTERS, default: "all", description: "Time filter" },
      limit: { type: "integer", default: 10, maximum: MAX_SEARCH_LIMIT, description: "Number of results" },
      verbosity: VERBOSITY_SCHEMA
    },
    required: ["query"]
  )

  def self.call(query:, subreddit: nil, sort: "relevance", time: "all", limit: 10, verbosity: DEFAULT_VERBOSITY, server_context:)
    service = server_context[:service]

    query = query.to_s.strip
    return error_response("query is required") if query.empty?

    if subreddit
      subreddit = normalize_subreddit(subreddit)
      return error_response("subreddit must be a valid name") unless subreddit
    end

    return error_response("sort must be one of: #{SEARCH_SORTS.join(', ')}") unless SEARCH_SORTS.include?(sort)
    return error_response("time must be one of: #{TIME_FILTERS.join(', ')}") unless TIME_FILTERS.include?(time)

    result = service.search(query: query, subreddit: subreddit, sort: sort, time: time, limit: limit.to_i.clamp(1, MAX_SEARCH_LIMIT), verbosity: normalize_verbosity(verbosity))
    MCP::Tool::Response.new([{ type: "text", text: result }])
  end
end

class RedditPostTool < MCP::Tool
  extend RedditToolHelpers
  description "Get a Reddit post with comments. Use comment_limit/comment_depth to fetch more."

  input_schema(
    properties: {
      post_id: { type: "string", description: "Reddit post ID (e.g., '1abc123')" },
      comment_limit: { type: "integer", default: 15, maximum: MAX_COMMENT_LIMIT, description: "Max comments" },
      comment_depth: { type: "integer", default: 2, maximum: MAX_COMMENT_DEPTH, description: "Reply depth" },
      verbosity: VERBOSITY_SCHEMA
    },
    required: ["post_id"]
  )

  def self.call(post_id:, comment_limit: 15, comment_depth: 2, verbosity: DEFAULT_VERBOSITY, server_context:)
    service = server_context[:service]

    post_id = normalize_post_id(post_id)
    return error_response("post_id is required and must be valid") unless post_id

    result = service.post(
      post_id: post_id,
      comment_limit: comment_limit.to_i.clamp(1, MAX_COMMENT_LIMIT),
      comment_depth: comment_depth.to_i.clamp(1, MAX_COMMENT_DEPTH),
      verbosity: normalize_verbosity(verbosity)
    )
    MCP::Tool::Response.new([{ type: "text", text: result }])
  end
end

class RedditTrendingTool < MCP::Tool
  extend RedditToolHelpers
  description "Get trending/top posts from a subreddit. Good for understanding what's popular."

  input_schema(
    properties: {
      subreddit: { type: "string", description: "Subreddit name (e.g., 'selfhosted')" },
      time: { type: "string", enum: TIME_FILTERS, default: "week", description: "Time period" },
      limit: { type: "integer", default: 10, maximum: MAX_TRENDING_LIMIT, description: "Number of posts" },
      verbosity: VERBOSITY_SCHEMA
    },
    required: ["subreddit"]
  )

  def self.call(subreddit:, time: "week", limit: 10, verbosity: DEFAULT_VERBOSITY, server_context:)
    service = server_context[:service]

    subreddit = normalize_subreddit(subreddit)
    return error_response("subreddit is required and must be valid") unless subreddit

    return error_response("time must be one of: #{TIME_FILTERS.join(', ')}") unless TIME_FILTERS.include?(time)

    result = service.trending(subreddit: subreddit, time: time, limit: limit.to_i.clamp(1, MAX_TRENDING_LIMIT), verbosity: normalize_verbosity(verbosity))
    MCP::Tool::Response.new([{ type: "text", text: result }])
  end
end

# Run the server
if __FILE__ == $PROGRAM_NAME
  $stderr.puts "Reddit MCP Server started (output=#{DEFAULT_OUTPUT}, verbosity=#{DEFAULT_VERBOSITY})"

  client = RedditClient.new(user_agent: USER_AGENT)
  service = RedditService.new(client: client)

  server = MCP::Server.new(
    name: "reddit-mcp",
    version: "1.0.0",
    tools: [RedditSearchTool, RedditPostTool, RedditTrendingTool],
    server_context: { service: service }
  )

  transport = MCP::Server::Transports::StdioTransport.new(server)
  transport.open
end
