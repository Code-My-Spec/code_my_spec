defmodule CodeMySpecSpex.Story985.Criterion3039Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3039 — An agent that stops on an open task is told to close it.

  Rule: Stopping the agent, giving it work, and nudging it to finish its own are
  all recorded.

  ## This criterion was "work completed on the agent's behalf" until John read it

  > The agent should be nudged to complete its own task, but if it stops without
  > completing it, the orchestrator should either tell the agent to call complete
  > task ... actually on second thought we should attempt to automate task
  > completion. We should just tell the agent to do it in the stop hook. It
  > should always be at the agent's discretion.

  Completing work *for* an agent decides on its behalf whether the work is done,
  and that is the one judgement the agent is there to make. So the orchestrator
  tells it, and the telling is the thing on the record.

  On the task's own agent rather than the project's — "we don't care about
  showing this on the main agent's conversation". The agent that looks like it
  walked away is the one that needs the record.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
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

  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "Stopping the agent, giving it work, and nudging it to finish its own are all recorded" do
    scenario "An agent that stops on an open task is told to close it" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "an agent that has a task it has not completed", context do
        context =
          context
          |> given_a_main_checkout("the main checkout")
          |> then(&Map.put(&1, :conversation_path, main_conversation_path(&1)))

        context = Map.put(context, :agent_id, main_agent_id(context))

        # The task is this agent's, so the nudge reaches the thread of the agent
        # that would otherwise look like it walked away. Left implicit, the
        # record lands somewhere nobody is reading.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, started, _frame} =
          StartTask.execute(
            %{
              requirement_name: "stories_exist",
              entity_type: "project",
              entity_id: context.project.id,
              session_id: context.session_id,
              agent_id: context.agent_id
            },
            frame
          )

        refute started.isError, "could not give the agent a task: #{inspect(started)}"

        {:ok, context}
      end

      when_ "it tries to stop", context do
        use_cmd_cassette "clean", record: :none do
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
            "session_id" => context.session_id,
            "test_output_files" => @stop_test_output_files
          })
          |> then(fn conn ->
            assert conn.status == 200, "the stop hook did not answer: #{conn.status}"
          end)
        end

        {:ok, _live, html} = live(context.conn, context.conversation_path)

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "it is told to close that task itself", context do
        assert context.transcript =~ "orchestrator-action",
               "the agent stopped with work open and nothing said so. It comes back to " <>
                 "a transcript that gives it no reason to finish what it left."

        assert context.transcript =~ "evaluate_task",
               "the nudge does not name the thing to call. An agent told it left " <>
                 "something open, with no name for the act that closes it, has been " <>
                 "given a complaint rather than an instruction."

        # And it carries the whole call, task id included. John: "you should be
        # able to send it the precise evaluate task call with the task id."
        #
        # The shape rather than one particular id: the agent has more than one
        # task open here and the hook nudges about the oldest, which is its own
        # question. What this criterion turns on is that the agent is handed
        # something it can call, not a tool name and a puzzle.
        assert context.transcript =~ ~r/evaluate_task task_id: (&quot;|")[0-9a-f-]{36}\1/,
               "the nudge names the tool but not the task. The agent is left to " <>
                 "work out which of its tasks was meant by something that already " <>
                 "knew, which is how an instruction turns back into a complaint."

        {:ok, context}
      end

      then_ "and nothing completed the task for it", context do
        refute context.transcript =~ ~r/Finished .* for you/,
               "something closed the task on the agent's behalf. Deciding that work is " <>
                 "done is the judgement the agent is there to make, and taking it away " <>
                 "makes the record a report of what was assumed rather than of what was " <>
                 "decided."

        {:ok, context}
      end
    end
  end
end
