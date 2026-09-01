defmodule CodeMySpecSpex.Story985.Criterion3033Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3033 — A change of direction has its reason directly above it.

  Rule: An orchestrator action is recorded on the conversation itself, in order
  with the agent's own turns.

  The transcript records what the *agent* did. Everything the harness does *to*
  it — the stop hook firing, the analyzers running, the decision that came out —
  is absent, so a conversation that changes direction between one turn and the
  next has no explanation in it. Somebody reading sees the agent doing one thing,
  then another, and the reason lives in a log on a different machine.

  ## Why a row rather than its own table

  John's call in the Three Amigos: a fourth value on `conversation_messages.role`.
  Interleaving is the whole point, and one ordered stream interleaves for free —
  a second table means every reader merges two of them and has to get ties right.

  ## What this drives

  The stop hook, which is where a real stop decision comes from, and then the
  transcript the person is reading. Two endpoints: hooks are on
  `CodeMySpecLocalWeb` and the conversation is on `CodeMySpecWeb`, so the hook is
  dispatched explicitly rather than through `~p`.
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

  spex "An orchestrator action is recorded on the conversation itself, in order with the agent's own turns" do
    scenario "A change of direction has its reason directly above it" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "an agent that has been working on one thing", context do
        {:ok, given_a_main_checkout(context, "the main checkout")}
      end

      when_ "the orchestrator stops it and gives it something else", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
          "session_id" => context.session_id
        })

        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "the transcript shows what the orchestrator did", context do
        assert context.transcript =~ "orchestrator-action",
               "the conversation records what the agent did and nothing about what was " <>
                 "done to it. A transcript that changes direction with no reason in it " <>
                 "sends the reader to a log on another machine, which is the whole of " <>
                 "this story."

        {:ok, context}
      end

      then_ "and it sits in order with the agent's own turns", context do
        # In the one ordered stream, not appended after it or drawn in a
        # separate panel. Interleaving is what makes "directly above" mean
        # anything — the reason has to be next to the change it explains.
        assert context.transcript =~ ~r/data-test="(conversation-message|orchestrator-action)"/,
               "the action is rendered somewhere other than the transcript's own stream, " <>
                 "so it cannot sit directly above the turn it explains."

        {:ok, context}
      end
    end
  end
end
