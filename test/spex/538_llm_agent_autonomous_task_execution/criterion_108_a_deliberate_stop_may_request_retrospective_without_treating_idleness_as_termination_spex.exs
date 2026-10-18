defmodule CodeMySpecSpex.Story538.Criterion1500Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 1500 — A deliberate stop may request retrospective without treating idleness as termination.

  Ordinary queue exhaustion must not produce a termination retrospective or
  clear continuous. A subsequent deliberate user stop changes that intent but
  does not stop the durable process. A retrospective affordance is optional:
  this scenario does not require a message where silence is permitted.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
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

  spex "Idle and deliberately stopped are different outcomes", criterion: 108 do
    scenario "Queue exhaustion emits no retrospective before the user deliberately stops continuous" do
      given_ "a continuous coding agent has completed its work and has no eligible coding requirement",
             context do
        context = given_a_staffed_checkout(context, "spex_1500")
        context = FullSatisfactionFixtures.apply_without_qa_story(context)

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, response), response_text(response)

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)

        {agent, completed_task} =
          Fixtures.agent_task_fixture(context.scope, agent,
            status: :completed,
            requirement_name: "bdd_specs_exist",
            story_id: context.story.id
          )

        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(agent_frame.assigns, :scope, agent_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ completed_task.id
        assert response_text(tasks) =~ "[completed]"
        refute response_text(tasks) =~ "[active]"
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        # The server has observed a turn start; its next incoming event is
        # the boundary being tested. The local engine is ready for admission.
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: agent.id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent),
           history_before: Machine.history(agent.id),
           conversation_before: response_text(conversation),
           tasks_before: response_text(tasks)
         })}
      end

      when_ "the harness reports that the turn has ended", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "the same agent stays idle without another turn or operator message", context do
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert HeldProvider.seen() == []

        conversation =
          ToolLibrary.run(
            "read_agent_conversation",
            %{agent_id: context.agent_id},
            Map.put(frame(context).assigns, :scope, frame(context).assigns[:current_scope])
          )

        assert match?({:ok, _}, conversation), response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        refute response_text(conversation) =~ ~r/retrospective|loop terminat/i

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
        assert Fixtures.role_queue_size(context.scope, context.agent_id) == 0

        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the user deliberately disables continuous and the stop decision runs", context do
        {:ok, view, _} = live(context.conn, context.conversation_path)
        view |> element("[data-test='toggle-agent-working']") |> render_click()
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "the deliberate stop preserves the agent and task history without an unsolicited retrospective turn",
            context do
        assert {:ok, %{busy?: false}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []

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
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='false']")
        {:ok, context}
      end
    end
  end
end
