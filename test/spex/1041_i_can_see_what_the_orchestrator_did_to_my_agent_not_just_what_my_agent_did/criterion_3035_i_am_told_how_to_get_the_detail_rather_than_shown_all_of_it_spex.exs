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
  use ExCliVcr

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  @impl_path "lib/example_context.ex"
  @fixture_dir "test/fixtures/validation/pipeline_compile_error"

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
    # Half of the same rule, and the half that catches the failure QA found: the
    # count has to be *this* decision's, so a decision that found nothing has to
    # say nothing rather than report whatever else is on the board.
    #
    # Same fixture as the scenario below, minus the write. The diagnostic lands
    # on a file this session never touched, so it is advisory, the stop allows,
    # and the project still holds one problem. That gap between "what is
    # recorded" and "what this stop decided" is the whole defect, and it is why
    # the blocking scenario cannot catch it alone — there the two numbers happen
    # to agree.
    #
    # First, because scenarios in one spex share a project and a conversation:
    # run after the block and this transcript already carries the block's count.
    scenario "a stop that found nothing does not borrow somebody else's number" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a problem on a file this session never touched", context do
        context = given_a_main_checkout(context, "the main checkout")
        {:ok, Map.put(context, :conversation_path, main_conversation_path(context))}
      end

      when_ "the agent stops and is let go", context do
        conn =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
          end

        refute Phoenix.ConnTest.json_response(conn, 200)["decision"] == "block",
               "the stop blocked, so this is not the allow case and the premise " <>
                 "never held."

        {:ok, _live, html} = live(context.conn, context.conversation_path)

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "the action is there and carries no count", context do
        assert context.transcript =~ "orchestrator-action",
               "the allow was not recorded at all. An allow is the agent being let " <>
                 "go, which is as much a thing that happened to it as a block."

        refute context.transcript =~ ~r/data-test="orchestrator-action-count"/,
               "the stop found nothing and reported a number anyway. That number is " <>
                 "the project's standing backlog, and a reader takes it for what this " <>
                 "decision found — concluding the analyzers found problems and waved " <>
                 "the agent through."

        assert context.transcript =~ "list_problems",
               "with no number, the tool name is the only way left to go and look."

        {:ok, context}
      end
    end

    scenario "I am told how to get the detail rather than shown all of it" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "a stop decision that found problems", context do
        context = given_a_main_checkout(context, "the main checkout")

        # The file has to be *changed* as well as broken. Problems are scoped to
        # what this session touched, so a diagnostic on a file nobody edited is
        # advisory and the stop allows — which is what this spex did before QA
        # read it, and why an assertion that only checked "a count is present"
        # passed on the project's standing backlog instead of on this decision.
        :ok = Environments.write_file(context.environment, @impl_path, broken_impl())

        # Opening the conversation is what brings the project's agent into
        # being — `given_a_main_checkout/2` designates the checkout and stops
        # there. Without this the hook fires while `main_agent/1` is still nil,
        # the recorder correctly does nothing, and the `then_` reads as the
        # feature being absent when the premise never held.
        {:ok, Map.put(context, :conversation_path, main_conversation_path(context))}
      end

      when_ "I read that action in the transcript", context do
        # The stop hook is where a real stop decision comes from. Dispatched
        # explicitly because hooks live on `CodeMySpecLocalWeb` while the
        # conversation is on `CodeMySpecWeb`, and `~p` would reach the wrong
        # router.
        conn =
          use_cmd_cassette "pipeline_compile_error", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
              "session_id" => context.session_id,
              # A stop that found nothing has nothing to count, and this
              # criterion is about what an action says when there *is*
              # something. Fed the same way the 555 spex feed analyzer output,
              # so the problems are real records rather than a number written
              # into the assertion.
              "test_output_files" => %{"compile" => fixture_path("compile.jsonl")}
            })
          end

        # A `when_` whose own action quietly did nothing produces a `then_` that
        # fails for the wrong reason, and reads as the feature being missing
        # rather than the step never having run.
        assert conn.status == 200, "the stop hook did not answer: #{conn.status}"

        assert Phoenix.ConnTest.json_response(conn, 200)["decision"] == "block",
               "the stop allowed, so there is no decision here that found anything. " <>
                 "A count asserted against an allowed stop is a count of something else."

        {:ok, _live, html} = live(context.conn, context.conversation_path)

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "it says what happened and how much of it there is", context do
        assert context.transcript =~ "orchestrator-action",
               "no action is recorded, so it says neither."

        assert context.transcript =~ ~r/data-test="orchestrator-action-count"/,
               "the action does not say how many. Without a number, one problem and " <>
                 "forty read the same and the reader cannot tell whether to look."

        # And the number is this decision's own. It was the project's standing
        # backlog until QA read it — an allow that found nothing rendered "476
        # problems", then "500" an hour later — and an assertion that only
        # checks the span exists cannot tell those apart. One compile error
        # went in above.
        assert context.transcript =~ ~r/orchestrator-action-count.*?>\s*1 problem\s*</s,
               "the count is not what this stop found. One problem went in; any other " <>
                 "number is somebody else's tally being reported as this decision's " <>
                 "finding, which is worse than no number at all."

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

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))

  defp broken_impl do
    """
    defmodule ExampleContext do
      # missing `end`
    """
  end
end
