defmodule CodeMySpecSpex.Story1054.Criterion3274Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3274 — An agent that stopped reporting is not shown as working.

  Rule: holding a task is not the same as doing it.

  The one failure on this story that actively misleads rather than merely
  omitting. An agent that died mid-task leaves the task open, and a view that
  reports what it holds says "working on story X" about a process that stopped
  hours ago — confidently, and in exactly the words a healthy agent would
  produce. The main agent then reports progress upward that is not happening,
  and the longer it goes on the more convincing it looks.

  So the claim is two-sided and both halves are asserted. The silence has to be
  visible, *and* the held task must not be dressed up as current work. A view
  that showed the silence somewhere while still leading with "working on X"
  would satisfy half a criterion and mislead exactly as much.

  Note what it does not say: that the agent is dead. The main agent decides
  that, from the parts — 3275 is the criterion that forbids the view from
  ruling on it, and 3279 is the case where a long silence is not a stall at
  all. This one only forbids the confident wrong answer.
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

  spex "A held task is not reported as work in progress" do
    scenario "an agent has said nothing for a long time" do
      given_ "an agent holding a task that has been silent for two hours", context do
        reply = join_working_copy(context, "/tmp/spex-3274", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story = CodeMySpecSpex.Fixtures.authored_story(scope, "Invoices export to CSV")

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3274"
          )

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            story_id: story.id,
            started_at: DateTime.add(DateTime.utc_now(), -2 * 60 * 60, :second)
          )

        # It spoke once, two hours ago, and has not since. Backdated rather than
        # waited for.
        :ok = CodeMySpecSpex.Fixtures.agent_said(scope, agent, "starting on the exporter")
        :ok = CodeMySpecSpex.Fixtures.age_agent_messages(scope, agent, 2 * 60 * 60)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at what its agents are doing", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "the silence is visible and the task is not reported as progress",
            context do
        assert context.view =~ ~r/silent|last (said|spoke|heard)|no message/i,
               """
               The agent's silence is nowhere in the view.

               It has held a task for two hours and said nothing, and the view
               reads exactly as it would for an agent that started a minute ago.
               The main agent has no way to tell the difference, so it reports
               progress that is not happening — and the longer this goes on the
               more convincing the report looks.

               view:
               #{context.view}
               """

        refute context.view =~ ~r/(currently |now )?working on/i,
               """
               A silent agent's held task is being reported as work in progress.

               Showing the silence somewhere while still leading with "working
               on" satisfies half the criterion and misleads exactly as much:
               the reader takes the confident phrase and skips the caveat, which
               is what confident phrases are for.

               Holding a task is not doing it. What the silence *means* is the
               main agent's call to make from the parts — criterion 3275 — and
               3279 is the case where it means nothing at all. This criterion
               only forbids answering it here, wrongly.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
