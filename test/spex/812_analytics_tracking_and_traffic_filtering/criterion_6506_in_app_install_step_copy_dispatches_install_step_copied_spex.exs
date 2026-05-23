defmodule CodeMySpecSpex.Story812.Criterion6506Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6506 — Rule 2: In-app install step copy dispatches
  `:install_step_copied` with `user_id` + `step`.

  Browser-API endpoint pattern (mirrors 6502): authenticated user
  clicks copy on an install-step row in the /app onboarding panel,
  the click handler POSTs to `/api/browser/analytics/event`, server
  dispatches MP carrying user_id + step identifier.

  ## Recording

      mix test test/spex/812_.../criterion_6506_*.exs --include ga_cassette_record
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_install_step_copied"
  @cassette_dir "test/cassettes/analytics"

  @moduletag :ga_cassette_record

  setup :register_log_in_setup_account

  spex "In-app install step copy dispatches :install_step_copied with step" do
    scenario "POST to /api/browser/analytics/event carries user_id + step" do
      given_ "an authenticated user on /app with a chosen install step", context do
        payload = %{
          "name" => "install_step_copied",
          "params" => %{
            "step" => "claude_code_install",
            "user_id" => context.user.id
          }
        }

        {:ok, Map.put(context, :payload, payload)}
      end

      when_ "the click handler POSTs to /api/browser/analytics/event", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            context.conn
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.post("/api/browser/analytics/event", context.payload)
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured install_step_copied with user_id + step", context do
        assert_cassette_contains_mp_event(@cassette_name, "install_step_copied",
          expected_params: %{
            "step" => "claude_code_install",
            "user_id" => context.user.id
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
