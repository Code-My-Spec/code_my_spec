defmodule CodeMySpecSpex.Story704.Criterion6100Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6100 — Human approves the tap-out and continuous mode clears.

  Covers Rule 5's approval path: after a pending tap_out request is
  approved through the permission flow, `session.continuous` is
  cleared and the next stop hook allows.

  ## Surface

  In production the approval rides Claude Code's
  `PermissionRequest` → `approve` binary flow already wired in
  `hooks.json`. For test, the spex drives the approval through the
  bridge fixture `Fixtures.respond_to_tap_out/4`, which wraps the
  same `Permissions.TapOut.respond/4` function the production
  webhook will call.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Human approves the tap-out and continuous mode clears" do
    scenario "after approval, continuous is false and next stop hook allows" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "continuous mode is enabled and tap_out has been called", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          TapOut.execute(%{session_id: context.session_id}, frame)

        body = TaskResponseHelpers.response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([^`]+)`/, body)

        {:ok, Map.put(context, :request_id, request_id)}
      end

      when_ "the human approves the pending tap-out request", context do
        {:ok, _session} =
          Fixtures.respond_to_tap_out(
            context.scope,
            context.session_id,
            context.request_id,
            :approve
          )

        {:ok, context}
      end

      then_ "the next stop hook allows the stop (continuous cleared, observed via surface)",
            context do
        # "continuous flag is cleared" is observable through the stop
        # hook: if the flag were still on with actionable work, stop
        # would block with a continuation directive. The empty allow
        # signal is the surface confirmation that continuous cleared.
        response =
          use_cmd_cassette "clean", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
                "compile" =>
                  Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl")
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        assert response == %{},
               "expected stop to allow after tap-out approval, got: #{inspect(response)}"

        {:ok, context}
      end
    end
  end
end
