defmodule CodeMySpecSpex.Story812.Criterion6498Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6498 — Rule 1: Server-side page_view dispatches on every
  browser-pipeline pageload.

  Cassette-assertion: a GET to any page in the browser pipeline fires
  exactly one MP page_view POST carrying `path`, `referrer`, and
  `user_agent` params.

  Driving spec — will FAIL until the page_view plug ships. Pairs with
  6499 (mobile-webview), 6500 (Reddit attribution), 6501 (bot filter).

  ## Recording

      mix test test/spex/812_.../criterion_6498_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_page_view_per_pageload"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "Server-side page_view dispatches on every browser-pipeline pageload" do
    scenario "GET / fires one page_view MP POST with path/referrer/user_agent" do
      given_ "a visitor with a normal browser user-agent", context do
        conn =
          context.conn
          |> Plug.Conn.put_req_header(
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
          )
          |> Plug.Conn.put_req_header("referer", "https://example.com/some-page")

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "they GET any page in the browser pipeline", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn -> Phoenix.ConnTest.get(context.conn, "/") end)
        end

        {:ok, context}
      end

      then_ "the cassette captured a page_view MP POST with path=\"/\"", context do
        assert_cassette_contains_mp_event(@cassette_name, "page_view",
          expected_params: %{"path" => "/"},
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
