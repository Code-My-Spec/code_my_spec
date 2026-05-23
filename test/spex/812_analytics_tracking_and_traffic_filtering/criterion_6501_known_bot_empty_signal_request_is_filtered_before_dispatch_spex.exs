defmodule CodeMySpecSpex.Story812.Criterion6501Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6501 — Rule 1: Known-bot / empty-signal request is
  filtered before dispatch.

  Cassette-assertion (negative): a request with a known-bot
  user-agent OR with both empty Referer + empty User-Agent does NOT
  fire a page_view MP POST. The plug evaluates the request and skips
  the dispatch before MP.

  Driving spec — will FAIL until the page_view plug both (a) ships
  and (b) carries the bot-filter predicate. The MP HTTPAdapter cassette
  records nothing on these requests, so the assertion is "the cassette
  contains zero page_view interactions for the test."
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette
  import CodeMySpecSpex.GaAssertions, only: [with_ga_plug: 2]

  @cassette_name "812_page_view_bot_filtered"
  @cassette_dir "test/cassettes/analytics"

  @bot_ua "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

  @moduletag :ga_cassette_record

  spex "Known-bot / empty-signal request is filtered before dispatch" do
    scenario "Googlebot UA hits the pipeline; no page_view MP POST gets recorded" do
      given_ "a request with a known-bot User-Agent", context do
        conn = Plug.Conn.put_req_header(context.conn, "user-agent", @bot_ua)
        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the request hits the browser pipeline", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn -> Phoenix.ConnTest.get(context.conn, "/") end)
        end

        {:ok, context}
      end

      then_ "the cassette contains no page_view MP POSTs", context do
        path = Path.join(@cassette_dir, @cassette_name <> ".json")
        json = File.read!(path)
        data = Jason.decode!(json)
        interactions = data["interactions"] || []

        page_view_posts =
          Enum.filter(interactions, fn interaction ->
            request = interaction["request"] || %{}

            request["method"] == "POST" and
              is_binary(request["uri"]) and
              String.starts_with?(request["uri"], "https://www.google-analytics.com/mp/collect") and
              get_in(request, ["body_json", "events"])
              |> List.wrap()
              |> Enum.any?(fn event -> event["name"] == "page_view" end)
          end)

        assert page_view_posts == [],
               """
               Expected zero page_view MP POSTs from a bot UA, but cassette has #{length(page_view_posts)}:

               #{Enum.map_join(page_view_posts, "\n", fn i -> "  " <> inspect(i["request"]["body_json"]) end)}
               """

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
