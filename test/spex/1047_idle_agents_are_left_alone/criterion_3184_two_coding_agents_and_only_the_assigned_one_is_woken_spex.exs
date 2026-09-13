defmodule CodeMySpecSpex.Story1047.Criterion3184Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3184 — Two coding agents, and only the assigned one is woken.

  3179 separates roles on one copy. This separates copies for one role, and it
  is the separation that gets missed: two coding agents on two checkouts have
  the same role, the same project and the same graph, so anything keyed on role
  alone wakes both and looks right doing it.

  What the second agent does when woken is the damage. It is not idle-and-wrong
  — it is working on a different epic, and a wake against work it is not
  assigned invites it to pick that work up. Two agents on one story in two
  checkouts is the failure the working-copy grain exists to prevent, and it
  arrives here through a doorbell rather than through an assignment.

  Two real checkouts, joined the way a harness joins, because a copy that is
  only a row has no agents to leave alone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is woken for work on its own checkout and no other" do
    scenario "Two coding agents, and only the assigned one is woken" do
      given_ "the project chain is past kickoff, so role work is the frontier", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a working copy assigned to one epic, with a coding agent on it", context do
        first = join_working_copy(context, "/tmp/spex-3184-a", "the first checkout")
        scope = %{context.scope | active_working_copy_id: first.working_copy_id}

        epic = Fixtures.epic_fixture(scope)

        {:reply, reply, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: to_string(epic.id), working_copy_id: first.working_copy_id},
            frame(%{context | scope: scope})
          )

        refute reply.isError, "the premise is an epic assigned to the first checkout"

        agent =
          Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3184-a")

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:first_epic, epic)
         |> Map.put(:first_agent, agent.id)}
      end

      given_ "a second working copy on a different epic, with its own coding agent", context do
        second = join_working_copy(context, "/tmp/spex-3184-b", "the second checkout")
        scope = %{context.scope | active_working_copy_id: second.working_copy_id}

        other_epic = Fixtures.epic_fixture(scope)

        {:reply, reply, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: to_string(other_epic.id), working_copy_id: second.working_copy_id},
            frame(%{context | scope: scope})
          )

        refute reply.isError, "the premise is a second epic on the second checkout"

        agent =
          Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3184-b")

        {:ok,
         context
         |> Map.put(:second_agent, agent.id)
         |> Map.put(:first_before, heard_count(context, context.first_agent))
         |> Map.put(:second_before, heard_count(context, agent.id))}
      end

      when_ "a story in the first epic becomes ready for coding", context do
        story = Fixtures.authored_story(context.scope, "Refunds reach the ledger")
        :ok = Fixtures.put_story_in_epic(context.scope, story, context.first_epic)
        :ok = Fixtures.mark_story_ready(context.scope, story)

        {:ok, put_to_work(context)}
      end

      then_ "the coding agent on the first working copy is nudged", context do
        assert heard_count(context, context.first_agent) > context.first_before,
               """
               The agent on the checkout the work was assigned to heard
               nothing, so this scenario cannot say anything about the agent on
               the other one.
               """

        {:ok, context}
      end

      then_ "and the coding agent on the second working copy is sent nothing", context do
        refute_told_anything(
          context,
          context.second_agent,
          context.second_before,
          """
          An agent on a checkout the work was not assigned to was woken for it.

          It is not idle-and-wrong; it is part-way through a different epic,
          and a wake naming work it is not assigned invites it to pick that
          work up. Two agents on one story in two checkouts is the failure the
          working-copy grain exists to prevent — arriving through a doorbell
          rather than through an assignment.
          """
        )

        {:ok, context}
      end
    end
  end
end
