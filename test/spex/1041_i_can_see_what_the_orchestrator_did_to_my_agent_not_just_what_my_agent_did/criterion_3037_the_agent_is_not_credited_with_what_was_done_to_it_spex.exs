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
  use ExCliVcr

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  # See criterion 3059's note: an uncassetted stop runs a real `mix compile`
  # and a real recursive `mix spex`, which has nothing to do with what this
  # criterion checks.
  @stop_test_output_files %{
    "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
    "compile" => Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl")
  }

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
        use_cmd_cassette "clean", record: :none do
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
            "session_id" => context.session_id,
            "test_output_files" => @stop_test_output_files
          })
          |> then(fn conn ->
            # A `when_` whose own action quietly did nothing produces a `then_`
            # that fails for the wrong reason, and reads as the feature being
            # missing rather than the step never having run.
            assert conn.status == 200,
                   "the stop hook did not answer: #{conn.status}"
          end)
        end

        {:ok, _live, html} = live(context.conn, context.conversation_path)

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
