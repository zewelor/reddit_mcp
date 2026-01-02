require "minitest/autorun"
require_relative "../server"

class FakeClient
  def initialize(payload)
    @payload = payload
  end

  def get_json(_url, retries: 3)
    @payload
  end
end

class RedditServiceTest < Minitest::Test
  def test_comment_depth_and_limit
    payload = build_post_payload
    service = RedditService.new(client: FakeClient.new(payload))

    # Test with full verbosity (has author names and footer)
    shallow = service.post(post_id: "abc123", comment_limit: 2, comment_depth: 1, verbosity: "full")
    refute_includes(shallow, "**u/child**")
    assert_includes(shallow, "Showing 2 comments")

    deep = service.post(post_id: "abc123", comment_limit: 3, comment_depth: 2, verbosity: "full")
    assert_includes(deep, "**u/child**")
    assert_includes(deep, "Showing 3 comments")

    # Test compact verbosity (no author names, no footer)
    compact = service.post(post_id: "abc123", comment_limit: 2, comment_depth: 1, verbosity: "compact")
    assert_includes(compact, "[5p]")
    refute_includes(compact, "**u/parent**")
    refute_includes(compact, "Showing")
  end

  def test_search_returns_formatted_results
    payload = {
      "data" => {
        "children" => [
          {
            "data" => {
              "id" => "abc123",
              "title" => "Test post",
              "subreddit" => "ruby",
              "score" => 42,
              "num_comments" => 5,
              "selftext" => "Test content"
            }
          }
        ]
      }
    }
    service = RedditService.new(client: FakeClient.new(payload))

    # Test full verbosity
    full = service.search(query: "test", subreddit: nil, sort: "relevance", time: "all", limit: 10, verbosity: "full")
    assert_includes(full, "Test post")
    assert_includes(full, "r/ruby")
    assert_includes(full, "42 pts")

    # Test compact verbosity (default)
    compact = service.search(query: "test", subreddit: nil, sort: "relevance", time: "all", limit: 10, verbosity: "compact")
    assert_includes(compact, "Test post")
    assert_includes(compact, "42p")
    assert_includes(compact, "[abc123]")
  end

  def test_trending_returns_formatted_results
    payload = {
      "data" => {
        "children" => [
          {
            "data" => {
              "id" => "xyz789",
              "title" => "Trending post",
              "subreddit" => "programming",
              "score" => 100,
              "num_comments" => 20,
              "selftext" => ""
            }
          }
        ]
      }
    }
    service = RedditService.new(client: FakeClient.new(payload))

    # Test full verbosity
    full = service.trending(subreddit: "programming", time: "week", limit: 10, verbosity: "full")
    assert_includes(full, "Trending post")
    assert_includes(full, "r/programming")
    assert_includes(full, "100 pts")

    # Test compact verbosity
    compact = service.trending(subreddit: "programming", time: "week", limit: 10, verbosity: "compact")
    assert_includes(compact, "Trending post")
    assert_includes(compact, "100p")
    assert_includes(compact, "[xyz789]")
  end

  private

  def build_post_payload
    post_listing = {
      "data" => {
        "children" => [
          {
            "data" => {
              "title" => "Test post",
              "subreddit" => "ruby",
              "score" => 1,
              "num_comments" => 2,
              "author" => "author",
              "created_utc" => Time.now.to_i,
              "selftext" => ""
            }
          }
        ]
      }
    }

    comments_listing = {
      "data" => {
        "children" => [
          {
            "data" => {
              "author" => "parent",
              "score" => 5,
              "body" => "Parent comment",
              "replies" => {
                "data" => {
                  "children" => [
                    {
                      "data" => {
                        "author" => "child",
                        "score" => 2,
                        "body" => "Child comment"
                      }
                    }
                  ]
                }
              }
            }
          },
          {
            "data" => {
              "author" => "second",
              "score" => 3,
              "body" => "Second comment",
              "replies" => ""
            }
          }
        ]
      }
    }

    [post_listing, comments_listing]
  end
end

class RedditToolValidationTest < Minitest::Test
  def test_normalize_subreddit_strips_prefix
    assert_equal "ruby", RedditSearchTool.normalize_subreddit("r/ruby")
    assert_equal "Ruby", RedditSearchTool.normalize_subreddit("Ruby")
    assert_equal "self_hosted", RedditSearchTool.normalize_subreddit("self_hosted")
  end

  def test_normalize_subreddit_rejects_invalid
    assert_nil RedditSearchTool.normalize_subreddit("")
    assert_nil RedditSearchTool.normalize_subreddit("   ")
    assert_nil RedditSearchTool.normalize_subreddit("invalid-name")
    assert_nil RedditSearchTool.normalize_subreddit("has spaces")
  end

  def test_normalize_post_id_strips_prefix
    assert_equal "abc123", RedditPostTool.normalize_post_id("t3_abc123")
    assert_equal "abc123", RedditPostTool.normalize_post_id("abc123")
  end

  def test_normalize_post_id_rejects_invalid
    assert_nil RedditPostTool.normalize_post_id("")
    assert_nil RedditPostTool.normalize_post_id("   ")
    assert_nil RedditPostTool.normalize_post_id("invalid-id")
  end
end

class TextFormatterTest < Minitest::Test
  def setup
    @formatter = TextFormatter.new
  end

  def test_time_ago_formats_correctly
    now = Time.now.to_i
    assert_equal "just now", @formatter.time_ago(now)
    assert_equal "5m ago", @formatter.time_ago(now - 300)
    assert_equal "2h ago", @formatter.time_ago(now - 7200)
    assert_equal "1d ago", @formatter.time_ago(now - 86400)
  end

  def test_preview_text_truncates
    short = "Short text"
    long = "A" * 300

    assert_includes @formatter.preview_text(short, 200), short
    assert_includes @formatter.preview_text(long, 200), "..."
  end

  def test_preview_text_handles_empty
    assert_equal "", @formatter.preview_text(nil, 200)
    assert_equal "", @formatter.preview_text("", 200)
    assert_equal "", @formatter.preview_text("   ", 200)
  end
end
