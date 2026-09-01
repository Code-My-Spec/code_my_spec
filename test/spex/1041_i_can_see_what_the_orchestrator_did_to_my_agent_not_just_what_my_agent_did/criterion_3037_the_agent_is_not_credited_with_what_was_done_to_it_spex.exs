defmodule CodeMySpecSpex.Story985.Criterion3037Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3037 — The agent is not credited with what was done to it

  Rule: An orchestrator action is not rendered as something the agent did.

  From the story: "Not tool-use blocks — the agent did not call these and
  rendering them as calls would say it did."

  A distinct kind, rendered alongside them. `ChatComponents` already draws three
  kinds side by side, so this is a fourth rather than a new surface.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # An agent refused for want of a credential never reaches a conversation, and
  # this story is entirely about what a conversation shows.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "An orchestrator action is not rendered as something the agent did." do
    scenario "The agent is not credited with what was done to it" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a stop decision on the agent's conversation", context do
        {:ok, given_a_main_checkout(context, "the main checkout")}
      end

      when_ "I read the transcript", context do
        # The stop hook is where a real stop decision comes from. Dispatched
        # explicitly because hooks live on `CodeMySpecLocalWeb` while the
        # conversation is on `CodeMySpecWeb`, and `~p` would reach the wrong
        # router.
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
          "session_id" => context.session_id
        })

        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "it does not read as a tool the agent called", context do
        actions =
          Regex.scan(~r/data-test="orchestrator-action"/, context.transcript) |> length()

        assert actions > 0,
               "nothing was recorded, so this criterion cannot be observed either way."

        refute context.transcript =~ ~r/data-test="tool-call"[^>]*orchestrator/,
               "the orchestrator's action is drawn as a tool call. The agent did not " <>
                 "call it, and rendering it as a call says it did."

        {:ok, context}
      end

      then_ "and nothing suggests the agent chose to stop itself", context do
        refute context.transcript =~ ~r/data-test="orchestrator-action"[^>]*data-role="assistant"/,
               "the action is attributed to the agent. What was done *to* it reading as " <>
                 "something it did is worse than not recording it — the reader draws a " <>
                 "conclusion about the agent's judgement from the orchestrator's."

        {:ok, context}
      end
    end
  end
end
