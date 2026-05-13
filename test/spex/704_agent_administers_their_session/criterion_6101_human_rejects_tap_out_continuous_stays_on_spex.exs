defmodule CodeMySpecSpex.Story704.Criterion6101Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6101 — Human rejects the tap-out and continuous mode stays on.

  Covers Rule 5's rejection path: after a pending tap_out request is
  rejected, `session.continuous` stays on, the next stop hook still
  blocks with the autonomous-loop continuation directive, and the
  rejection is observable on the PubSub topic the agent can monitor.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpec.Permissions.TapOut, as: TapOutCore
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Human rejects the tap-out and continuous mode stays on" do
    scenario "after rejection, continuous remains true and next stop hook still blocks" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "continuous mode is enabled and tap_out has been called", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)

        Phoenix.PubSub.subscribe(CodeMySpec.PubSub, TapOutCore.topic())

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          TapOut.execute(%{session_id: context.session_id}, frame)

        body = TaskResponseHelpers.response_text(response)
        [_, request_id] = Regex.run(~r/request_id=`([^`]+)`/, body)

        # Drain the request-broadcast so the rejection assertion can
        # consume the next message without ordering surprises.
        receive do
          {:tap_out_requested, _, _} -> :ok
        after
          500 -> :ok
        end

        {:ok, Map.put(context, :request_id, request_id)}
      end

      when_ "the human rejects the pending tap-out request", context do
        {:ok, _session} =
          Fixtures.respond_to_tap_out(
            context.scope,
            context.session_id,
            context.request_id,
            :reject
          )

        {:ok, context}
      end

      then_ "the next stop hook still blocks with the continuation directive (continuous still on)",
            context do
        # "continuous stays on" is observable through the stop hook:
        # the autonomous-loop block-with-directive only fires when the
        # flag is on. The DB-read of session.continuous would be a
        # boundary violation; the stop hook is the user-facing signal.
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        assert response["decision"] == "block",
               "expected stop to still block in continuous mode after tap-out rejection, got: #{inspect(response)}"

        assert response["reason"] =~ "start_task",
               "expected the continuation directive in the block reason, got: #{inspect(response)}"

        {:ok, context}
      end

      and_ "the rejection is observable on the permissions:tap_out PubSub topic",
           context do
        receive do
          {:tap_out_decision, request_id, :reject} when request_id == context.request_id ->
            :ok
        after
          500 ->
            flunk("expected a {:tap_out_decision, _, :reject} PubSub message")
        end

        {:ok, context}
      end
    end
  end
end
