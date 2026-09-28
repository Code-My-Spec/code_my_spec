defmodule CodeMySpecSpex.Story1017.Criterion2416Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2416 — A task-free menu invents neither questions nor work.

  At an empty turn boundary, no fabricated question count or task directive
  may reach the conversation or provider. The durable agent remains idle
  with its continuous intent intact; silence must not silently disable it.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
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

  spex "A task-free empty stop invents neither questions nor work", criterion: 909 do
    scenario "No question count or task directive is delivered and continuous remains enabled" do
      given_ "a continuous task-free coding agent has no eligible work", context do
        context = given_a_staffed_checkout(context, "spex_2416")
        context = ProjectStateFixtures.apply_project_kickoff(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        agent_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        # The server has observed a turn start; its next incoming event is
        # the boundary being tested. The local engine is ready for admission.
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: agent.id}, frame(context))

        refute conversation.isError, response_text(conversation)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           agent_frame: agent_frame,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent),
           history_before: Machine.history(agent.id),
           conversation_before: response_text(conversation)
         })}
      end

      when_ "the harness reports that the turn has ended", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "the same agent stays idle without another turn or operator message", context do
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert Machine.history(context.agent_id) == context.history_before
        assert HeldProvider.seen() == []

        {:reply, conversation, _} =
          ReadAgentConversation.execute(%{agent_id: context.agent_id}, frame(context))

        refute conversation.isError, response_text(conversation)
        assert response_text(conversation) == context.conversation_before
        refute response_text(conversation) =~ ~r/\b\d+\s+(?:open\s+)?questions?\b/i

        {:reply, tasks, _} = ListTasks.execute(%{}, context.agent_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."

        {:reply, questions, _} = ListUserQuestions.execute(%{}, context.agent_frame)
        refute questions.isError, response_text(questions)
        refute response_text(questions) =~ ~r/\b[1-9]\d*\s+open questions?\b/i

        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
