# frozen_string_literal: true

require_relative "base"

# Markdown/text output formatter
class TextFormatter < BaseFormatter
  FULL_FOOTER = "\n---\nUse `reddit_post` with a post_id to see full content and comments."

  def format_search(posts, query:, subreddit:, verbosity:)
    if verbosity == "full"
      if subreddit
        output = "# Search results for \"#{query}\" in r/#{subreddit}\n\n"
      else
        output = "# Search results for \"#{query}\" (all Reddit)\n\n"
      end
    else
      sub_part = subreddit ? "r/#{subreddit}" : "all"
      output = "#{query} @ #{sub_part}\n\n"
    end

    posts.each_with_index do |post, idx|
      output << format_post_preview(post["data"], idx + 1, verbosity: verbosity)
    end

    output << FULL_FOOTER if verbosity == "full"
    output
  end

  def format_trending(posts, subreddit:, time:, verbosity:)
    if verbosity == "full"
      output = "# Trending in r/#{subreddit} (top #{time})\n\n"
    else
      output = "r/#{subreddit} top #{time}\n\n"
    end

    posts.each_with_index do |post, idx|
      output << format_post_preview(post["data"], idx + 1, verbosity: verbosity)
    end

    output << FULL_FOOTER if verbosity == "full"
    output
  end

  def format_post(post_data, comments_data, comment_depth:, comment_limit:, verbosity:)
    output = format_full_post(post_data, verbosity: verbosity)
    output << (verbosity == "full" ? "\n## Top Comments\n\n" : "---\nComments:\n\n")

    if comments_data.empty?
      output << "_No comments yet_\n"
    else
      comments_output, count = format_comments(comments_data, comment_depth, comment_limit, verbosity: verbosity)
      if comments_output.empty?
        output << "_No comments yet_\n"
      else
        output << comments_output
        output << "\n---\nShowing #{count} comments (depth #{comment_depth}, limit #{comment_limit})." if verbosity == "full"
      end
    end
    output
  end

  def format_post_preview(p, num, verbosity:)
    if verbosity == "full"
      result = "### #{num}. #{p['title']}\n"
      result << "**r/#{p['subreddit']}** | #{p['score']} pts | #{p['num_comments']} comments | id: `#{p['id']}`\n"
      preview = preview_text(p["selftext"], 200)
      result << "> #{preview}\n" unless preview.empty?
      result << "\n"
    else
      # compact & minimal use same format for listings
      preview = preview_text(p["selftext"], 150)
      result = "#{num}. #{p['title']} [#{p['id']}] #{p['score']}p #{p['num_comments']}c"
      result << "\n   #{preview}" unless preview.empty?
      result << "\n"
    end
    result
  end

  def format_full_post(p, verbosity:)
    if verbosity == "full"
      output = "# #{p['title']}\n\n"
      output << "**Subreddit:** r/#{p['subreddit']} | **Score:** #{p['score']} | **Comments:** #{p['num_comments']}\n"
      output << "**Author:** u/#{p['author']} | **Posted:** #{time_ago(p['created_utc'])}\n\n"
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
    else
      # compact & minimal use same format for post body
      output = "#{p['title']}\nr/#{p['subreddit']} | #{p['score']}p #{p['num_comments']}c\n\n"
      if p["selftext"] && !p["selftext"].empty?
        text = p["selftext"].length > 2000 ? p["selftext"][0..2000] + "..." : p["selftext"]
        output << "#{text}\n\n"
      elsif p["url"] && !p["url"].include?("reddit.com")
        output << "Link: #{p['url']}\n\n"
      end
    end
    output
  end

  def format_comments(comments, max_depth, max_count, verbosity:, indent: 0)
    output = +""
    count = 0

    comments.each do |comment|
      break if count >= max_count
      c = comment["data"]
      next unless c && c["body"]

      output << format_comment(c, indent, verbosity: verbosity)
      count += 1

      next unless max_depth > 1
      replies = c["replies"]
      next unless replies.is_a?(Hash)
      children = replies.dig("data", "children")
      next unless children.is_a?(Array) && !children.empty?

      child_output, child_count = format_comments(children, max_depth - 1, max_count - count, verbosity: verbosity, indent: indent + 1)
      output << child_output
      count += child_count
    end

    [output, count]
  end

  def format_comment(c, indent, verbosity:)
    prefix = "  " * indent
    body = truncate_body(c["body"])

    case verbosity
    when "full"
      output = "#{prefix}**u/#{c['author']}** (#{c['score']} pts):\n"
      body.lines.each { |line| output << "#{prefix}> #{line}" }
      output << "\n\n"
    when "compact"
      output = "#{prefix}[#{c['score']}p] #{body.lines.first&.strip || ''}"
      body.lines.drop(1).each { |line| output << "\n#{prefix}#{line.rstrip}" } if body.lines.count > 1
      output << "\n\n"
    else # minimal
      output = "#{prefix}- #{body.lines.first&.strip || ''}"
      body.lines.drop(1).each { |line| output << "\n#{prefix}  #{line.rstrip}" } if body.lines.count > 1
      output << "\n"
    end
    output
  end

  def error(msg)
    "Error: #{msg}"
  end

  def empty_result
    "No results found"
  end
end
