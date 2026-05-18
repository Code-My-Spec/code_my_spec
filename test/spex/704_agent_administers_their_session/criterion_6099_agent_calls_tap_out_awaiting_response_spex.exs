defmodule CodeMySpecSpex.Story704.Criterion6099Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6099 — Agent calls tap_out and gets an immediate
  awaiting-approval response.

  Covers Rule 5's request side: `tap_out` MCP tool registers a
  pending request, broadcasts to the `permissions:tap_out` PubSub
  topic, and returns immediately. The session's `continuous` flag
  is unchanged at the time the call returns.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "tap_out returns awaiting and publishes a permission request" do
    scenario "MCP call returns awaiting response; PubSub message observed; continuous still on" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "continuous mode is enabled on this session", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)

        Phoenix.PubSub.subscribe(CodeMySpec.PubSub, Fixtures.tap_out_pubsub_topic())

        {:ok, context}
      end

      when_ "the agent calls tap_out", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          TapOut.execute(%{session_id: context.session_id}, frame)

        {:ok,
         Map.merge(context, %{
           response: response,
           response_text: TaskResponseHelpers.response_text(response)
         })}
      end

      then_ "the response indicates the request is awaiting human approval", context do
        refute context.response.isError,
               "expected tap_out to succeed, got: #{context.response_text}"

        assert context.response_text =~ ~r/awaiting/i,
               "expected awaiting-approval language, got:\n#{context.response_text}"

        assert context.response_text =~ "request_id=",
               "expected response to include a request_id, got:\n#{context.response_text}"

        {:ok, context}
      end

      and_ "the next stop hook still blocks with continuous-mode continuation directive (continuous unchanged)",
           context do
        # The "continuous flag is still on" claim is observable through
        # the stop hook: if the flag had cleared, stop would allow with
        # %{}. We assert the block still fires with the autonomous-loop
        # directive — that's what "continuous still on" means at the
        # public surface.
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        assert response["decision"] == "block",
               "expected continuous mode to still block (tap-out unresolved), got: #{inspect(response)}"

        {:ok, context}
      end

      and_ "a tap-out request has been broadcast on the permissions:tap_out PubSub topic",
           context do
        session_id = context.session_id

        receive do
          {:tap_out_requested, request_id, ^session_id} when is_binary(request_id) ->
            :ok
        after
          500 ->
            flunk("expected a {:tap_out_requested, _, session_id} PubSub message")
        end

        {:ok, context}
      end
    end
  end
end
