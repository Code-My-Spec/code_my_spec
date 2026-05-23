defmodule CodeMySpecSpex.Story812.Criterion6502Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6502 — Rule 2: Homepage hero install-card copy fires
  `install_command_copy`.

  Browser-API endpoint pattern: when a visitor clicks an install card,
  JS POSTs to `/api/browser/analytics/event` with the event name and
  params. The controller dispatches via `Analytics.dispatch/3` and the
  MP POST lands at GA. We bypass the JS layer here by POSTing the
  browser endpoint directly with the same payload the hero card's
  data attributes would produce.

  ## Recording

      mix test test/spex/812_.../criterion_6502_*.exs --include ga_cassette_record

  Cassette: `test/cassettes/analytics/812_install_command_copy_hero.json`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_install_command_copy_hero"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  spex "Homepage hero install-card copy fires install_command_copy with location + harness" do
    scenario "POST to /api/browser/analytics/event dispatches MP with hero placement" do
      given_ "the four install-card placements + harness payload the hero card produces", context do
        params = %{
          "name" => "install_command_copy",
          "params" => %{
            "location" => "homepage_hero",
            "harness" => "codemyspec"
          }
        }

        {:ok, Map.put(context, :payload, params)}
      end

      when_ "JS POSTs the click to /api/browser/analytics/event", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            context.conn
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.post("/api/browser/analytics/event", context.payload)
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured install_command_copy with location=homepage_hero",
            context do
        assert_cassette_contains_mp_event(@cassette_name, "install_command_copy",
          expected_params: %{
            "location" => "homepage_hero",
            "harness" => "codemyspec"
          },
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
