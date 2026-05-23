defmodule CodeMySpecSpex.Story812.Criterion6499Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6499 — Rule 1: Mobile-webview pageloads still fire
  page_view.

  Cassette-assertion: a GET with a mobile in-app-browser user-agent
  (Facebook / Instagram / X webview) still fires the server-side
  page_view MP POST. Because the plug runs server-side and doesn't
  depend on gtag.js loading in the browser, the webview's JS
  limitations don't suppress the event.

  Driving spec — will FAIL until the page_view plug ships.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_page_view_mobile_webview"
  @cassette_dir "test/cassettes/analytics"

  # Instagram in-app browser user-agent (representative webview client).
  @ua "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 300.0.0.20.108 (iPhone15,3; iOS 17_0; en_US; en-US; scale=3.00; 1290x2796; 519062300)"

  @moduletag :ga_cassette_record

  spex "Mobile-webview pageloads still fire page_view" do
    scenario "an Instagram webview GET fires the server-side page_view" do
      given_ "a visitor opens a cms deeplink in a mobile in-app browser", context do
        conn = Plug.Conn.put_req_header(context.conn, "user-agent", @ua)
        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the page renders", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn -> Phoenix.ConnTest.get(context.conn, "/") end)
        end

        {:ok, context}
      end

      then_ "the cassette captured a page_view MP POST", context do
        assert_cassette_contains_mp_event(@cassette_name, "page_view",
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
