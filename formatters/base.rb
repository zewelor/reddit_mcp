# frozen_string_literal: true

# Base formatter with shared utilities
class BaseFormatter
  def preview_text(text, max_len)
    return "" if text.nil? || text.empty?
    clean = text.gsub(/\s+/, " ").strip
    return "" if clean.empty?
    clean.length > max_len ? clean[0..max_len] + "..." : clean
  end

  def truncate_body(text, max_len = 800)
    return "" if text.nil?
    body = text.to_s.gsub(/\n{3,}/, "\n\n")
    body.length > max_len ? body[0..max_len] + "..." : body
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
