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
  alias CodeMySpecSpex.StoryHelpers
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

      given_ :synced_context_component

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
         |> Map.put(:second_copy_id, second.working_copy_id)}
      end

      given_ "a story interviewed into the first epic, parked", context do
        # Parked, linked and interviewed, so that releasing it is the one thing
        # left and what it puts on the graph is `bdd_specs_exist` — coding's.
        # A bare story projects `component_linked` and `three_amigos_complete`,
        # both product's, so the coding lane never moved and neither agent
        # could have been woken by it.
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refunds reach the ledger",
            description: "Assigned to the first checkout",
            acceptance_criteria: ["A refund lands on the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        :ok = Fixtures.put_story_in_epic(context.scope, story, context.first_epic)

        # Re-placing the epic is what carries the assignment down to the story:
        # `EpicDispatch.place/3` stamps `working_copy_id` on every story the
        # epic holds *at that moment*, and this one joined afterwards. Without
        # it the story is unassigned, and `assigned_here_or_unassigned/2` offers
        # an unassigned story to every checkout — so the second agent would be
        # woken correctly and the criterion would fail for being right.
        {:reply, reply, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{
              epic_id: to_string(context.first_epic.id),
              working_copy_id: context.scope.active_working_copy_id
            },
            frame(context)
          )

        refute reply.isError, "the premise is the story assigned to the first checkout"

        {:ok, Map.put(context, :story, story)}
      end

      given_ "both checkouts switched on", context do
        context =
          context
          |> put_to_work()
          |> put_to_work(context.second_copy_id)

        {:ok,
         context
         |> Map.put(:first_before, heard_count(context, context.first_agent))
         |> Map.put(:second_before, heard_count(context, context.second_agent))}
      end

      when_ "the story is released, putting its specs in the first checkout's lane", context do
        :ok = Fixtures.mark_story_ready(context.scope, context.story)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
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
