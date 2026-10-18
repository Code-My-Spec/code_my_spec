defmodule CodeMySpecSpex.Story1017.Criterion2415Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2415 — The active-task menu scopes outstanding question information.

  A real question and two explicit task claims establish the task boundary.
  The harness turn-end event must deliver a disposition menu, not suppress it
  because an unrelated task is waiting on the user.
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

  spex "The active task's disposition menu survives an unrelated unanswered question",
    criterion: 908 do
    scenario "An unanswered question is identified with its blocked task, not used as a global gate" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_2415")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "the agent asks against one task and explicitly takes independent work", context do
        [first, second] =
          Enum.map(["Refund policy", "Receipt layout"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent work for task-scoped stop information",
                acceptance_criteria: ["The stated behavior is specified"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            story
          end)

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        first_claim =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(first.number)
            },
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, first_claim), response_text(first_claim)
        blocked_task_id = extract_task_id!(first_claim)

        question =
          ToolLibrary.run(
            "ask_user_question",
            %{
              task_id: blocked_task_id,
              questions: [
                %{
                  question: "Which refund period applies?",
                  options: [%{label: "14 days"}, %{label: "30 days"}]
                }
              ]
            },
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, question), response_text(question)

        second_claim =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(second.number)
            },
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, second_claim), response_text(second_claim)
        active_task_id = extract_task_id!(second_claim)
        assert active_task_id != blocked_task_id

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        before_menu =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: agent.id, limit: 1},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, before_menu), response_text(before_menu)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           blocked_task_id: blocked_task_id,
           active_task_id: active_task_id,
           conversation_before: response_text(before_menu)
         })}
      end

      when_ "the agent reports its turn ended through the harness", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "a new menu offers disposition of the active task despite the open question",
            context do
        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id, limit: 1},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        text = response_text(conversation)
        assert text != context.conversation_before
        assert text =~ context.active_task_id
        assert text =~ "evaluate_task"
        assert text =~ "cancel_task"
        assert text =~ "tap_out"
        assert text =~ context.blocked_task_id

        assert text =~
                 ~r/question.*(?:open|waiting|unanswered)|(?:open|waiting|unanswered).*question/is

        refute text =~ ~r/(?:must|have to) answer.*before.*(?:continu|disposition)/is

        active =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, active), response_text(active)
        assert response_text(active) =~ "# Tasks (1)"
        assert response_text(active) =~ context.active_task_id
        refute response_text(active) =~ context.blocked_task_id

        blocked =
          ToolLibrary.run(
            "list_tasks",
            %{status: "blocked"},
            Map.put(
              context.agent_frame.assigns,
              :scope,
              context.agent_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, blocked), response_text(blocked)
        assert response_text(blocked) =~ "# Tasks (1)"
        assert response_text(blocked) =~ context.blocked_task_id
        refute response_text(blocked) =~ context.active_task_id
        {:ok, context}
      end
    end
  end
end
