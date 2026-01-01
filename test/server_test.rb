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

class RedditMCPServerTest < Minitest::Test
  def test_notifications_initialized_returns_nil
    server = RedditMCPServer.new
    response = server.send(:handle_request, { "jsonrpc" => "2.0", "method" => "notifications/initialized" })
    assert_nil response
  end

  def test_method_not_found_is_jsonrpc_error
    server = RedditMCPServer.new
    response = server.send(:handle_request, { "jsonrpc" => "2.0", "id" => 1, "method" => "nope" })
    assert_equal(-32601, response[:error][:code])
    assert_nil response[:result]
  end

  def test_invalid_post_id_is_jsonrpc_error
    server = RedditMCPServer.new
    response = server.send(
      :handle_request,
      {
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => { "name" => "reddit_post", "arguments" => { "post_id" => "" } }
      }
    )
    assert_equal(-32602, response[:error][:code])
  end

  def test_comment_depth_and_limit
    payload = build_post_payload
    service = RedditService.new(client: FakeClient.new(payload), formatter: RedditFormatter.new)

    shallow = service.post(post_id: "abc123", comment_limit: 2, comment_depth: 1)
    refute_includes(shallow, "**u/child**")
    assert_includes(shallow, "Showing 2 comments")

    deep = service.post(post_id: "abc123", comment_limit: 3, comment_depth: 2)
    assert_includes(deep, "**u/child**")
    assert_includes(deep, "Showing 3 comments")
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
