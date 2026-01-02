# frozen_string_literal: true

require_relative "base"

# JSON output formatter
class JsonFormatter < BaseFormatter
  def format_search(posts, query:, subreddit:, verbosity:)
    format_post_list(posts, verbosity: verbosity)
  end

  def format_trending(posts, subreddit:, time:, verbosity:)
    format_post_list(posts, verbosity: verbosity)
  end

  def format_post_list(posts, verbosity:)
    results = posts.map { |post| format_post_preview(post["data"], verbosity: verbosity) }
    JSON.generate(results)
  end

  def format_post(post_data, comments_data, comment_depth:, comment_limit:, verbosity:)
    result = format_full_post(post_data, verbosity: verbosity)
    comments, _count = format_comments(comments_data, comment_depth, comment_limit, verbosity: verbosity)
    result[:comments] = comments unless comments.empty?
    JSON.generate(result)
  end

  def format_post_preview(p, verbosity:)
    result = {
      t: p["title"],
      id: p["id"],
      p: p["score"],
      c: p["num_comments"]
    }
    preview = preview_text(p["selftext"], 150)
    result[:s] = preview unless preview.empty?

    if verbosity == "full"
      result[:r] = p["subreddit"]
      result[:a] = p["author"]
    end
    result
  end

  def format_full_post(p, verbosity:)
    result = {
      t: p["title"],
      r: p["subreddit"],
      p: p["score"],
      c: p["num_comments"]
    }
    result[:b] = p["selftext"]&.slice(0, 2000) if p["selftext"] && !p["selftext"].empty?

    if verbosity == "full"
      result[:a] = p["author"]
      result[:ts] = p["created_utc"]
    end
    result
  end

  def format_comments(comments, max_depth, max_count, verbosity:)
    result = []
    count = 0

    comments.each do |comment|
      break if count >= max_count
      c = comment["data"]
      next unless c && c["body"]

      body = truncate_body(c["body"])

      # Build entry based on verbosity
      entry = case verbosity
              when "full"
                { p: c["score"], a: c["author"], b: body }
              when "compact"
                [c["score"], body]
              else # minimal
                [body]
              end

      if max_depth > 1
        replies = c["replies"]
        if replies.is_a?(Hash)
          children = replies.dig("data", "children")
          if children.is_a?(Array) && !children.empty?
            child_result, child_count = format_comments(children, max_depth - 1, max_count - count - 1, verbosity: verbosity)
            unless child_result.empty?
              if verbosity == "full"
                entry[:replies] = child_result
              else
                entry << child_result
              end
            end
            count += child_count
          end
        end
      end

      result << entry
      count += 1
    end

    [result, count]
  end

  def error(msg)
    JSON.generate({ error: msg })
  end

  def empty_result
    "[]"
  end
end
