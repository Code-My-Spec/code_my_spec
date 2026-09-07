defmodule CodeMySpecSpex.Story538.Criterion5124Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5124 — When the agent voluntarily taps out of continuous
  mode, the request is routed to PermissionSocket for human approval.

  Covers Rule R8's tap-out clause: "Optionally the agent can
  voluntarily tap out of continuous mode earlier; the request is
  routed through PermissionSocket for human approval."

  ## Surface

  The autonomous loop has a `tap_out` MCP tool the agent can invoke
  mid-loop. Calling it must (a) be non-blocking — the agent never
  waits in-line for the human, (b) keep the loop running until the
  human responds (continuous stays on), and (c) flip continuous off
  once the human approves. End-to-end: tap_out → respond_to_tap_out
  (:approve) → next stop allows.

  ## Relation to Story 704's tap-out coverage

  Story 704 owns the agent-tooling lens for tap-out:
  - 6099 — tap_out returns awaiting + publishes a permission request
  - 6100 — human approves → continuous clears
  - 6101 — human rejects → continuous stays on

  This criterion exists at the 538 layer because it asserts the loop's
  participation in the flow: an autonomous-loop session can exit via
  this voluntary path. The surface choices match 704's because the
  tool is the same; the assertion focus is the loop transitioning out
  of continuous after approval, not the MCP tool's response shape.
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

  spex "Voluntary tap-out routes to human approval; loop terminates on approve" do
    scenario "agent taps out from the loop; human approves; next stop allows (loop ended)" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the autonomous loop is running (continuous mode on)", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      given_ "the agent has voluntarily tapped out of the loop", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          TapOut.execute(%{session_id: context.session_id}, frame)

        body = TaskResponseHelpers.response_text(response)

        # The tap_out tool must hand back a request_id so the loop can
        # continue without blocking on human input — this is the
        # "non-blocking voluntary exit" guarantee. Pattern-match raises
        # at this setup boundary if the contract is broken (rather than
        # leaving a then_ to discover a missing request_id later).
        [_, request_id] = Regex.run(~r/request_id=`([^`]+)`/, body)

        {:ok, Map.put(context, :tap_out_request_id, request_id)}
      end

      # "Continuous is still on until human approves" is covered by Story 704's
      # criterion 6099 at the agent-tooling layer; the 538 layer asserts the
      # post-approval loop transition, not the pre-approval steady-state.

      when_ "the human approves the routed tap-out request", context do
        {:ok, _session} =
          Fixtures.respond_to_tap_out(
            context.scope,
            context.session_id,
            context.tap_out_request_id,
            :approve
          )

        {:ok, context}
      end

      then_ "the autonomous loop has terminated — next stop is allowed", context do
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
               "loop must end after approval — expected empty allow, got: #{inspect(response)}"

        {:ok, context}
      end
    end
  end
end
