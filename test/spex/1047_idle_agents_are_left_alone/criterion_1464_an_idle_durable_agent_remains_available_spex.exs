defmodule CodeMySpecSpex.Story1047.Criterion3566Spex do
  @moduledoc """
  Story 1047 — Idle agents are left alone.
  Criterion 3566 — An idle durable agent remains available.

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

  spex "An idle durable role remains available", criterion: 1464 do
    scenario "An agent left idle accepts a later deliberate turn without a restart" do
      given_ "a continuous coding agent has finished a real turn with no eligible work remaining",
             context do
        context = given_a_staffed_checkout(context, "spex_3566")
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

      given_ "the completed turn has been reported and the agent is idle", context do
        :ok = Fixtures.end_turn(context.scope, context.agent_id, @end_turn_opts)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert HeldProvider.seen() == context.requests_before
        {:ok, context}
      end

      when_ "a later deliberate user message arrives", context do
        HeldProvider.hold()

        assert {:ok, :started} =
                 Machine.send_message(
                   context.agent_id,
                   "later-user-turn",
                   "Continue our conversation"
                 )

        HeldProvider.await_request()
        HeldProvider.release()
        :ok = Machine.await_idle(context.agent_id)
        {:ok, context}
      end

      then_ "the same process handles the later turn with its earlier context intact",
            context do
        assert Process.alive?(context.engine_pid)
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id)
        assert Enum.sort(Machine.running()) == context.roster_before
        assert {:ok, history} = Machine.history(context.agent_id)
        assert {:ok, previous_history} = context.history_before
        assert Enum.take(history, length(previous_history)) == previous_history
        assert length(history) > length(previous_history)
        assert length(HeldProvider.seen()) == length(context.requests_before) + 1
        assert Enum.any?(HeldProvider.seen(), &String.contains?(&1, "Continue our conversation"))
        {:ok, context}
      end
    end
  end
end
