defmodule CodeMySpecSpex.Story812.Criterion6519Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6519 — Rule 6: page_view originates from a server plug,
  never from gtag.

  Cassette-assertion pattern: a request to a browser-pipeline page
  fires exactly one MP page_view POST. Because gtag isn't loaded
  (criterion 6517), no client-side `gtag('event', 'page_view')` call
  ever happens — only the server-side dispatch lands.

  Driving spec — will FAIL until a request plug (probably
  `CodeMySpecWeb.Plugs.PageView` or similar) is added to the browser
  pipeline that dispatches `:page_view` via Analytics.dispatch with
  origin: :server.

  ## Recording

      mix test test/spex/812_.../criterion_6519_*.exs --include ga_cassette_record

  Cassette: `test/cassettes/analytics/812_page_view_from_plug.json`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_page_view_from_plug"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "page_view originates from a server plug, never from gtag" do
    scenario "GET / fires one page_view MP POST and the response carries no gtag" do
      given_ "a request to a browser-pipeline page with a real-browser UA", context do
        conn =
          Plug.Conn.put_req_header(
            context.conn,
            "user-agent",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
          )

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the visitor GETs /", context do
        conn =
          with_cassette @cassette_name, cassette_opts(), fn plug ->
            with_ga_plug(plug, fn ->
              Phoenix.ConnTest.get(context.conn, "/")
            end)
          end

        {:ok, Map.put(context, :conn_after, conn)}
      end

      then_ "the cassette captured one page_view MP POST", context do
        assert_cassette_contains_mp_event(@cassette_name, "page_view",
          cassette_dir: @cassette_dir
        )

        {:ok, context}
      end

      then_ "the response HTML carries no client-side gtag('event', 'page_view') call",
            context do
        body = context.conn_after.resp_body || ""

        refute body =~ ~r/gtag\s*\(\s*['"]event['"]\s*,\s*['"]page_view['"]/,
               "expected no client-side gtag('event', 'page_view') call in the response"

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
