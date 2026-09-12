defmodule CodeMySpecSpex.Story1054.Criterion3276Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3276 — A task opened an hour ago with nothing said for forty-five
  minutes.

  Rule: the two clocks are separate, because the gap between them is the
  information.

  3275 says four parts are handed over rather than a verdict. This says two of
  those parts are genuinely two: when the work started and when the agent last
  spoke are different moments, and collapsing them into one "last activity"
  figure destroys exactly the thing the main agent is trying to read.

  The worked example in the criterion is the reason. A task an hour old with
  forty-five minutes of silence is fifteen minutes of work and forty-five of
  nothing — which is a stall if the agent is alone, and ordinary if it is
  waiting on a review. One number cannot express it: "last activity an hour ago"
  and "last activity forty-five minutes ago" are both true of this agent and
  neither is the situation.

  ## What is asserted, and why not the numbers

  Two labelled facts, and that they carry different values. Not "45" and "60",
  because a view is free to render absolute times or relative ones and the
  criterion does not care which — it cares that there are two of them.

  A single combined figure fails on the missing label. A view that prints the
  same moment under both labels fails on the comparison, which is the shape a
  half-done implementation actually takes: one timestamp read twice.
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

  spex "When the work started and when the agent last spoke are both readable" do
    scenario "the task is an hour old and the agent has been quiet for forty-five minutes" do
      given_ "an agent whose task opened an hour ago and who last spoke forty-five minutes ago",
             context do
        reply = join_working_copy(context, "/tmp/spex-3276", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3276"
          )

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            started_at: DateTime.add(DateTime.utc_now(), -60 * 60, :second)
          )

        # Fifteen minutes of work, then silence. The gap between the two clocks
        # is the whole point, so they are set apart deliberately.
        :ok = CodeMySpecSpex.Fixtures.agent_said(scope, agent, "the migration is written")
        :ok = CodeMySpecSpex.Fixtures.age_agent_messages(scope, agent, 45 * 60)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "both times are there, and they are different times", context do
        started = labelled(context.view, ~r/task (opened|started)[^\n]*/i)
        spoke = labelled(context.view, ~r/last (said|spoke|message)[^\n]*/i)

        assert started,
               """
               When the agent's task opened is not in the view.

               view:
               #{context.view}
               """

        assert spoke,
               """
               When the agent last said anything is not in the view.

               A single "last activity" figure is the shape this fails as, and
               it is worse than leaving one out: both "an hour ago" and
               "forty-five minutes ago" are true of this agent, and neither is
               the situation.

               view:
               #{context.view}
               """

        refute started == spoke,
               """
               Both clocks are showing the same moment.

               This is what a half-done implementation looks like — one
               timestamp read twice under two labels — and it reads as a
               complete answer. Fifteen minutes of work followed by forty-five
               of silence is a stall if the agent is alone and ordinary if it is
               waiting on a review, and that judgement needs the gap between the
               two, not either one of them.

               task: #{started}
               last spoke: #{spoke}
               """

        {:ok, context}
      end
    end
  end

  defp labelled(view, pattern), do: first_line(Regex.run(pattern, view))

  defp first_line(nil), do: nil
  defp first_line([line | _]), do: String.trim(line)
end
