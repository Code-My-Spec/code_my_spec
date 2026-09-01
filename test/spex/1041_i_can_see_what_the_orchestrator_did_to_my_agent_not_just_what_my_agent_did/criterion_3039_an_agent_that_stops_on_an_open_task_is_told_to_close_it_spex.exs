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

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

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
          CodeMySpec.McpServers.Tasks.Tools.StartTask.execute(
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
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
          "session_id" => context.session_id
        })
        |> then(fn conn ->
          assert conn.status == 200, "the stop hook did not answer: #{conn.status}"
        end)

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
