defmodule CodeMySpecSpex.Story1048.Criterion3197Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3197 — The work is gone by the time the agent wakes.

  The race the design accepts rather than prevents. Waking is a publish with no
  claim on the work, so two idle agents can be woken by one story and one of
  them arrives second. Preventing that would mean assigning at wake time, which
  is the orchestrator this project declined.

  So the cost is moved to the loser, and the three Thens bound it.

  "Returns to idle without churning" is the one that fails expensively. An
  agent woken and then finding nothing has been told there is work — and a
  capable agent that believes there is work finds some. That is how a lost race
  turns into unrequested changes on a checkout, which is worse than the wasted
  turn.

  "Not woken again for that story" is what keeps the loss bounded. Without it
  the next recompute wakes it again for the same taken story, and two agents on
  one project trade the same wake indefinitely.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent that loses the race for work goes quietly back to idle" do
    scenario "The work is gone by the time the agent wakes" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component

      given_ "an idle coding agent woken by a message naming a ready story", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        :ok = Fixtures.mark_story_ready(context.scope, story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:story, story)
         |> Map.put(:woken_at, heard_count(context, coding.id))}
      end

      given_ "another agent has taken that story first", context do
        :ok = Fixtures.start_turn(context.scope, context.coding)

        other = Fixtures.running_agent(context.scope, role: "coding")

        {_agent, _task} =
          Fixtures.agent_task_fixture(context.scope, other, story_id: context.story.id)

        {:ok, Map.put(context, :other, other.id)}
      end

      when_ "the woken agent looks for the work", context do
        {:reply, reply, _frame} = GetNextRequirement.execute(%{}, frame(context))

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it finds nothing to do", context do
        text = inspect(context.reply)

        refute text =~ Regex.escape(context.story.title),
               """
               The agent that arrived second is still being offered the story
               another agent already holds.

               Two agents on one story in one project is the collision the
               task's own ownership exists to prevent, arriving here through a
               wake rather than an assignment.

               #{text}
               """

        {:ok, context}
      end

      then_ "and it returns to idle without churning", context do
        refute_told_anything(
          context,
          context.coding,
          context.woken_at,
          """
          Having found the work taken, the agent was handed something else.

          This is the expensive half. It was woken, so it believes there is
          work; it is capable, so it finds some — and a lost race becomes
          unrequested changes on a checkout, which is worse than the wasted
          turn.
          """
        )

        {:ok, context}
      end

      then_ "and it is not woken again for that story", context do
        :ok = Fixtures.settle_graph(context.scope)

        refute_told_anything(
          context,
          context.coding,
          context.woken_at,
          """
          The next recompute woke the agent for the same taken story.

          Without a bound here, two agents on one project trade the same wake
          indefinitely — each one woken, each one finding the work held by the
          other, neither able to stop being told about it.
          """
        )

        {:ok, context}
      end
    end
  end
end
