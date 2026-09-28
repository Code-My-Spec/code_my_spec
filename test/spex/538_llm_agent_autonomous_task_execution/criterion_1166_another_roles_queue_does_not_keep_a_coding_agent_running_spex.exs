defmodule CodeMySpecSpex.Story538.Criterion3106Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution.
  Criterion 3106 — Another role's queue does not keep a coding agent running.

  Product has a real incoming issue to triage, while coding's story is parked.
  At coding's turn boundary, the same engine stays idle and continuous remains
  enabled. Product's nonempty queue is not coding eligibility.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
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

  spex "Product work does not keep coding taking turns", criterion: 1166 do
    scenario "Coding ends its turn with no coding work while product triage stays pending" do
      given_ "a connected checkout has completed project kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3106")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous coding agent is idle before a story is released", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Criterion3106 refund posting",
            description: "The agent must choose this work itself",
            acceptance_criteria: ["A refund reaches the ledger"],
            ready_for_dev: false
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        {:reply, filed, _} =
          CreateIssue.execute(
            %{
              title: "Pending product triage for criterion 3106",
              description: "An unrelated incoming issue must not block coding",
              severity: "medium"
            },
            frame(context)
          )

        refute filed.isError, response_text(filed)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: false)
        product_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}
        {:reply, triage, _} = GetNextRequirement.execute(%{}, product_frame)
        refute triage.isError, response_text(triage)
        assert response_text(triage) =~ "issues_triaged"
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(agent.id)
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)
        coding_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent),
           product_frame: product_frame,
           coding_frame: coding_frame
         })}
      end

      when_ "coding reports the end of its turn", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "coding receives no turn while product's work remains available", context do
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == []
        assert Fixtures.role_queue_size(context.scope, context.agent_id) == 0

        {:reply, tasks, _} = ListTasks.execute(%{}, context.coding_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."

        {:reply, product, _} = GetNextRequirement.execute(%{}, context.product_frame)
        refute product.isError, response_text(product)
        assert response_text(product) =~ "issues_triaged"

        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end
    end
  end
end
