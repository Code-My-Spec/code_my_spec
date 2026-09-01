defmodule CodeMySpecSpex.Story985.Criterion3034Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3034 — Three analyzers skipped for one reason is one entry, not three

  Rule: One decision is one action, however many analyzers ran to reach it.

  A stop today produces a line per analyzer. Watching one live earlier: credo
  failed `:skipped_compile_errors`, exunit failed `:skipped_compile_errors`, spex
  failed `:skipped_compile_errors` — three records of one cause.

  Three entries all saying the same thing is the log. The person reading a
  transcript is reading it to understand a change of direction, and that change
  had one reason.
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

  spex "One decision is one action, however many analyzers ran to reach it." do
    scenario "Three analyzers skipped for one reason is one entry, not three" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a stop where the compile failed and the analyzers were skipped because of it", context do
        context = given_a_main_checkout(context, "the main checkout")

        # Opening the conversation is what brings the project's agent into
        # being — `given_a_main_checkout/2` designates the checkout and stops
        # there. Without this the hook fires while `main_agent/1` is still nil,
        # the recorder correctly does nothing, and the `then_` reads as the
        # feature being absent when the premise never held.
        {:ok, Map.put(context, :conversation_path, main_conversation_path(context))}
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
        |> then(fn conn ->
          # A `when_` whose own action quietly did nothing produces a `then_`
          # that fails for the wrong reason, and reads as the feature being
          # missing rather than the step never having run.
          assert conn.status == 200,
                 "the stop hook did not answer: #{conn.status}"
        end)

        {:ok, _live, html} = live(context.conn, context.conversation_path)

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "there is one orchestrator action, naming the decision and its reason", context do
        entries =
          Regex.scan(~r/data-test="orchestrator-action"/, context.transcript) |> length()

        assert entries == 1,
               "the stop produced #{entries} entries. One decision is one action — the " <>
                 "analyzers that were skipped are detail inside it, and a row each is " <>
                 "the log rather than the story."

        {:ok, context}
      end

      then_ "and the skipped analyzers are detail inside it rather than three entries",
            context do
        assert context.transcript =~ "orchestrator-action",
               "there is no action at all, so there is nothing for the analyzers to be " <>
                 "detail of."

        {:ok, context}
      end
    end
  end
end
