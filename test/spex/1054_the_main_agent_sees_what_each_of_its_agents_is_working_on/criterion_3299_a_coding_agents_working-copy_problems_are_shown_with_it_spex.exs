defmodule CodeMySpecSpex.Story1054.Criterion3299Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3299 — A coding agent's working-copy problems are shown with it.

  Rule: what is stopping an agent belongs beside the agent.

  Every other criterion here reports something about the agent. This one brings
  in something about the *checkout* — and the join is the point, because the two
  facts only mean anything together. Forty-eight problems on a working copy is a
  number; forty-eight problems on the copy where the coding agent has held a
  task for an hour is a diagnosis.

  The main agent could already have gone and looked: problems are listed per
  project and the agent names its copy. The criterion says it should not have
  to. That errand is what the story exists to remove, and it is the one most
  likely to be skipped — the agent's own row looks complete without it, so
  nothing prompts the second lookup.

  ## Why this and not "list_problems"

  `list_problems` answers "what is wrong on this project", which is the right
  answer to a different question and is where the main agent would end up. It
  cannot say which agent is blocked by what, because it does not know where any
  agent is standing. Only a view that holds both can.

  Problems are recorded the way an analyzer's reconciler records them, so
  "problems on the copy" means what the product means.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is shown with what is wrong where it is standing" do
    scenario "the copy a coding agent works in has problems on it" do
      given_ "a coding agent on a checkout carrying a compile failure", context do
        reply = join_working_copy(context, "/tmp/spex-3299", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3299"
          )

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file"
          )

        {:ok, _problems} =
          CodeMySpecSpex.Fixtures.record_problem(scope, "compiler", %{
            message: "undefined function collect_answers/2",
            file_path: "lib/my_app/refunds.ex",
            severity: :error
          })

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "the copy's problems are shown alongside the agent", context do
        assert context.view =~ ~r/problem/i,
               """
               The agent's working copy is carrying an error and its row says
               nothing about it.

               The main agent could go and look — problems are listed per
               project and the agent names its copy — and this criterion says it
               should not have to. That lookup is the one most likely to be
               skipped, because the agent's own row looks complete without it, so
               nothing prompts anybody to make it.

               view:
               #{context.view}
               """

        assert context.view =~ "undefined function collect_answers/2",
               """
               A count of problems is shown without saying what they are.

               "3 problems" against an agent is the same errand one step later:
               the main agent still has to go and find out whether they are its
               agent's doing, whether they block the task it holds, and whether
               a restart would clear them. Forty-eight problems on a copy is a
               number; the failure on the copy where this agent has held a task
               for an hour is a diagnosis.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
