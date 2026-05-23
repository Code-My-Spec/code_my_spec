defmodule CodeMySpecSpex.Story812.Criterion6500Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6500 — Rule 1: Reddit referrer attributes to Reddit,
  not (not set).

  Cassette-assertion: a GET with `Referer: https://www.reddit.com/...`
  fires a page_view MP POST whose params carry the Reddit source
  attribution — not blank, not "(not set)". GA buckets the session
  under Reddit traffic.

  Driving spec — will FAIL until the page_view plug both (a) ships
  and (b) extracts the source from the Referer header. Note: GA's
  own session-source bucketing is downstream of what we POST; this
  spex verifies the OUTBOUND payload carries the source.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_page_view_reddit_referrer"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "Reddit referrer attributes to Reddit, not (not set)" do
    scenario "GET with reddit.com referer fires page_view with source=reddit.com" do
      given_ "a visitor arrives with a Reddit referrer", context do
        conn =
          Plug.Conn.put_req_header(
            context.conn,
            "referer",
            "https://www.reddit.com/r/elixir/comments/abc123/example/"
          )

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the page renders and the plug dispatches :page_view", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn -> Phoenix.ConnTest.get(context.conn, "/") end)
        end

        {:ok, context}
      end

      then_ "the cassette captured page_view with source=\"reddit.com\"", context do
        assert_cassette_contains_mp_event(@cassette_name, "page_view",
          expected_params: %{"source" => "reddit.com"},
          cassette_dir: @cassette_dir
        )

        {:ok, context}
      end
    end
  end

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri, :body],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        {~r/api_secret=[^&\s"]+/, "api_secret=<REDACTED>"}
      ]
    ]
  end
end
