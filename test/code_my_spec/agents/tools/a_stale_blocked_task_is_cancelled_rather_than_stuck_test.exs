defmodule CodeMySpec.Agents.Tools.AStaleBlockedTaskIsCancelledRatherThanStuckTest do
  @moduledoc """
  f7a4b81e: a denied tap-out (or a withdrawn question) told an agent its
  blocked task was released and to resume it with `start_task` -- but in the
  window between that notice and the agent actually calling `start_task`,
  the requirement the task names can stop being eligible (something else
  resolved it, the project moved on). `start_task` then refused with a bare
  `:requirement_not_eligible`, leaving the task stuck `:blocked` forever --
  nothing auto-clears it, and the agent had no path forward except guessing
  to call `cancel_task` itself. `get_next_requirement` offered different
  work in the meantime, so the loop's own instruction ("resume task X") had
  become impossible to follow.

  Reproduced here with a single agent, matching the original report (no
  second agent involved): `Work.story_actionable/3` binds a story-role
  agent to its own current `story_id` (`Agents.Work.assignment/2`) and
  filters actionable nodes by that binding. If the team moves on to a
  different story while an old task sits blocked on an unrelated question,
  the old story's own requirement node is untouched and still resolves from
  the graph, but stops being actionable for this agent the moment its
  binding points elsewhere -- the exact shape of "still a real node, no
  longer this agent's to resume". `AgentsRepository.update_agent/3` writes
  `story_id` directly, the same field `assignment/2` reads, without going
  through `Assignment.claim/3`'s own refusal to move an already-bound agent
  (a guard this test is not exercising).
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  setup :synced_context_component

  defp reload({_status, text}) when is_binary(text), do: text

  defp reload(agent), do: CodeMySpec.Repo.get!(Agents.Agent, agent.id)

  test "a blocked task whose team has since moved to a different story is cancelled, not left stuck",
       context do
    context = ProjectStateFixtures.apply_project_kickoff(context)

    story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "A story whose task goes stale while blocked",
        description: "Blocked, the team moves on, released, and refused on resume.",
        acceptance_criteria: ["The stated behavior is implemented"]
      )

    :ok =
      ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
        persona_id: context.persona_id
      )

    coding = Fixtures.running_agent(context.scope, role: "coding")
    :ok = Agents.claim_story(context.scope, coding, story.id)

    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coding.id}}

    params = %{
      requirement_name: "bdd_specs_exist",
      entity_type: "story",
      entity_id: to_string(story.number)
    }

    started =
      ToolLibrary.run(
        "start_task",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, started), inspect(started)
    [task] = reload(coding).tasks

    asked =
      ToolLibrary.run(
        "ask_question",
        %{
          task_id: task.id,
          questions: [
            %{
              question: "Which criteria first?",
              options: [
                %{
                  label: "Keep current criteria",
                  description: "Implement the current acceptance criteria"
                },
                %{
                  label: "Revise criteria",
                  description: "Ask Product to revise the acceptance criteria"
                }
              ]
            }
          ]
        },
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, asked), inspect(asked)

    [%{status: :blocked, blocker_resolved_at: nil, blocker_id: question_id}] =
      reload(coding).tasks

    # The team moves on to a different story while the old task sits blocked
    # -- the story itself is untouched, so its node still resolves from the
    # graph, but assignment/2's binding now points elsewhere.
    other_story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "A later story the team moved on to",
        description: "Unrelated to the blocked task's own story.",
        acceptance_criteria: ["Something else entirely"]
      )

    {:ok, _} = AgentsRepository.update_agent(context.scope, coding, %{story_id: other_story.id})

    withdrawn =
      ToolLibrary.run(
        "withdraw_question",
        %{question_id: question_id, reason: "moot"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, withdrawn), inspect(withdrawn)
    assert [%{status: :blocked, blocker_resolved_at: %DateTime{}}] = reload(coding).tasks

    result =
      ToolLibrary.run(
        "start_task",
        params,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert {:error, text} = result,
           "start_task should refuse a resume the task is no longer eligible for: #{inspect(result)}"

    assert text =~ "get_next_requirement",
           "the refusal should point the agent at what to do next: #{text}"

    assert text =~ "no longer eligible"

    assert [%{id: task_id, status: :cancelled}] = reload(coding).tasks
    assert task_id == task.id
  end
end
