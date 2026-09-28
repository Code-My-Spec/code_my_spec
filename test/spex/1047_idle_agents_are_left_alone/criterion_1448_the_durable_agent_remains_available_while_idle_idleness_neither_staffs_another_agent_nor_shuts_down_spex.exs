defmodule CodeMySpecSpex.Story1047.Criterion3550Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3550 — Idleness neither staffs another agent nor shuts down the role.

  Preserve the actual PID and a completed turn's history, not merely a database
  row saying running. A replacement process with the same agent ID is not the
  same durable runtime.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2, frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
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

  spex "An idle durable role remains available", criterion: 1448 do
    scenario "Finishing a turn preserves the process and its conversation" do
      given_ "a continuous coding agent has finished a real turn with no eligible work remaining",
             context do
        context = given_a_staffed_checkout(context, "spex_3550")
        context = ProjectStateFixtures.apply_project_kickoff(context)
        {:reply, response, _} = GetNextRequirement.execute(%{}, frame(context))
        refute response.isError, response_text(response)

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        base_url = HeldProvider.start()

        assert {:ok, %{pid: pid}} =
                 Machine.start_agent(agent.id, context.copy, base_url: base_url)

        on_exit(fn -> Machine.stop_agent(agent.id) end)

        HeldProvider.hold()

        assert {:ok, :started} =
                 Machine.send_message(agent.id, "first-turn", "Remember this turn")

        HeldProvider.await_request()
        HeldProvider.release()
        :ok = Machine.await_idle(agent.id)
        assert {:ok, [_ | _]} = Machine.history(agent.id)
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           engine_pid: pid,
           history_before: Machine.history(agent.id),
           roster_before: Enum.sort(Machine.running()),
           requests_before: HeldProvider.seen()
         })}
      end

      when_ "the harness reports the completed turn", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        {:ok, context}
      end

      then_ "the same process remains available without staffing or another model request",
            context do
        assert Process.alive?(context.engine_pid)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert Enum.sort(Machine.running()) == context.roster_before
        assert Machine.history(context.agent_id) == context.history_before
        assert HeldProvider.seen() == context.requests_before
        {:ok, context}
      end
    end
  end
end
