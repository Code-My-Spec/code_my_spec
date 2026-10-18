defmodule CodeMySpecSpex.Story538.Criterion1495Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 1495 — Failed manual evaluation retains the same active task.

  The agent explicitly evaluates a real specification-writing task before its
  required files exist. Failure must be task-scoped feedback, not a transition
  to another task or another model turn.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Failed evaluation does not abandon the active task", criterion: 104 do
    scenario "Missing specification files produce scoped feedback without another task or turn" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_1495")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous agent owns a specification task whose files have not been written",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Keep working after failed evaluation",
            description: "Evaluation feedback must preserve the current attempt",
            acceptance_criteria: ["The agent retains the task when its specs are missing"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)
        task_id = extract_task_id!(started)

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ "[active]"
        assert response_text(tasks) =~ task_id

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           task_id: task_id,
           tasks_before: response_text(tasks)
         })}
      end

      when_ "the agent explicitly evaluates that unfinished task", context do
        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        {:ok, Map.put(context, :evaluation, response)}
      end

      then_ "the same task stays active and no new task or automatic model turn is admitted",
            context do
        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end

      then_ "the failed evaluation identifies the task and the missing work", context do
        assert match?({:ok, _}, context.evaluation), response_text(context.evaluation)
        text = response_text(context.evaluation)
        assert text =~ "Needs work"
        assert text =~ context.task_id
        assert text =~ ~r/missing|not.*exist|not.*found/i
        refute text =~ "Task completed successfully"
        {:ok, context}
      end
    end
  end
end
