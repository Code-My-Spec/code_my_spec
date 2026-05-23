defmodule CodeMySpecSpex.Story812.Criterion6503Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6503 — Rule 2: All four install-card placements fire
  with the right location.

  Browser-API endpoint pattern × 4: POSTs the install_command_copy
  event for each placement, asserts the cassette captured all four
  distinct location values.

  ## Recording

      mix test test/spex/812_.../criterion_6503_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_install_command_copy_four_placements"
  @cassette_dir "test/cassettes/analytics"

  @placements ~w(homepage_hero homepage_final_cta product_page_top product_page_final)

  @moduletag :ga_cassette_record

  spex "All four install-card placements fire with the right location" do
    scenario "each placement POSTs install_command_copy with its own location" do
      given_ "the four install-card placements", context do
        {:ok, Map.put(context, :placements, @placements)}
      end

      when_ "a visitor clicks copy on each placement", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            Enum.each(context.placements, fn location ->
              payload = %{
                "name" => "install_command_copy",
                "params" => %{
                  "location" => location,
                  "harness" => "codemyspec"
                }
              }

              context.conn
              |> Plug.Conn.put_req_header("content-type", "application/json")
              |> Phoenix.ConnTest.post("/api/browser/analytics/event", payload)
            end)
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured install_command_copy for each placement", context do
        Enum.each(context.placements, fn location ->
          assert_cassette_contains_mp_event(@cassette_name, "install_command_copy",
            expected_params: %{"location" => location, "harness" => "codemyspec"},
            cassette_dir: @cassette_dir
          )
        end)

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
