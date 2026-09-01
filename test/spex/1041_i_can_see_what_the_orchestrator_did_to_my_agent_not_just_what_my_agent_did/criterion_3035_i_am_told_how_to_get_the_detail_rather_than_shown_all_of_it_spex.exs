defmodule CodeMySpecSpex.Story985.Criterion3035Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3035 — I am told how to get the detail rather than shown all of it

  Rule: An action says what happened, how much of it there is, and which tool answers for the rest.

  John's call, and better than the alternative it replaced: the decision, a count,
  and the name of the tool that lists the rest. Not a link.

  A failing compile can produce dozens of problems, and a transcript that
  swallows them stops being readable at the moment it matters most. A decision
  with no number is no better — one problem and forty read identically, and the
  reader cannot tell whether to look.
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

  spex "An action says what happened, how much of it there is, and which tool answers for the rest." do
    scenario "I am told how to get the detail rather than shown all of it" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a stop decision that found problems", context do
        {:ok, given_a_main_checkout(context, "the main checkout")}
      end

      when_ "I read that action in the transcript", context do
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

      then_ "it says what happened and how much of it there is", context do
        assert context.transcript =~ "orchestrator-action",
               "no action is recorded, so it says neither."

        assert context.transcript =~ ~r/data-test="orchestrator-action-count"/,
               "the action does not say how many. Without a number, one problem and " <>
                 "forty read the same and the reader cannot tell whether to look."

        {:ok, context}
      end

      then_ "and it names the tool that lists them", context do
        assert context.transcript =~ "list_problems",
               "the action summarises and does not say how to get the rest. Half the " <>
                 "readers here are agents, and an agent cannot follow a link — what it " <>
                 "needs is the name of a tool it can call."

        {:ok, context}
      end

      then_ "and the problems themselves are not in the transcript", context do
        refute context.transcript =~ ~r/data-test="problem-detail"/,
               "the transcript swallowed the problems. A failing compile produces dozens " <>
                 "and the narrative stops being readable exactly when it matters."

        {:ok, context}
      end
    end
  end
end
