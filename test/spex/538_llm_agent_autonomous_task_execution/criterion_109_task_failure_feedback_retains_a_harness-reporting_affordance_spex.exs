defmodule CodeMySpecSpex.Story538.Criterion1501Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 1501 — Task failure feedback retains a harness-reporting affordance.

  A real failed evaluation reaches the turn-end decision. Its menu must keep
  the active task and missing-work feedback visible, with a framework issue
  reporting option rather than selecting replacement work.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @end_turn_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    exunit_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/exunit.json"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Failed-task stop feedback retains framework reporting", criterion: 109 do
    scenario "A failed evaluation leads to task-scoped feedback and a harness issue reporting option" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_1501")
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
           tasks_before: response_text(tasks),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the agent evaluates its unfinished specification task", context do
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

        assert match?({:ok, _}, response), response_text(response)
        assert response_text(response) =~ "Needs work"
        assert response_text(response) =~ "No valid spec names it"
        {:ok, context}
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

      when_ "the agent reports the end of its turn", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "continuous remains enabled and the original attempt is still the only task",
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
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      then_ "the latest menu identifies the failed task and offers framework issue reporting",
            context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id, limit: 1},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        text = response_text(conversation)
        assert text =~ context.task_id
        assert text =~ ~r/missing|not.*found/i
        assert text =~ "create_issue"
        assert text =~ ~r/scope[^\n]*framework/i
        refute text =~ ~r/start_task[^\n]*entity_id/i
        refute text =~ "Task completed successfully"
        {:ok, context}
      end
    end
  end
end
