defmodule CodeMySpec.Promotion.ALostRestartAcknowledgementIsVerifiedTest do
  @moduledoc """
  08744186: a restart whose acknowledgement is lost — the channel died
  answering it — used to end at "dispatched, not yet confirmed" whether the
  app came back or not. Promote now asks the app what it is serving, within a
  bounded wait, and reports "serving <commit>" or "restart failed: still on
  <old>".

  Git is scripted through the in-memory environment; the app is a fake
  registered in `HarnessRegistry`, answering the same `AppTransport` calls a
  harness would.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.QaFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Environments
  alias CodeMySpec.Files
  alias CodeMySpec.Promotion
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  @main "/lost-ack/main"
  @agent "/lost-ack/agent"
  @base "1111111111111111111111111111111111111111"
  @merged "2222222222222222222222222222222222222222"

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    # What Promotion reports, heard here directly. Delivering it to the agent is
    # `Agents.Events`' job, behind wake gates and a global transport; asserting
    # on the delivery made this test depend on all of that, and in the full
    # run (batch d724b12e5, 2026-10-05) the delivery never arrived.
    test = self()
    handler = {__MODULE__, test}

    :ok =
      :telemetry.attach(
        handler,
        [:code_my_spec, :promotion, :report],
        fn _event, _measurements, meta, _config ->
          send(test, {:reported, meta.agent_id, meta.text})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # The outcome is messaged from the detached restart task.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    :ok
  end

  # A fast-forward from `@base` to `@merged`.
  defp script do
    fn "git", args, opts -> answer(Keyword.fetch!(opts, :cd), args) end
  end

  defp answer(@agent, ["merge-base", "--is-ancestor", @base, "HEAD"]), do: {"", 0}
  defp answer(@agent, ["status" | _]), do: {"", 0}
  defp answer(@agent, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"story/x\n", 0}
  defp answer(@agent, ["rev-parse", "HEAD"]), do: {@merged <> "\n", 0}
  defp answer(@agent, ["ls-files" | _]), do: {"", 0}
  defp answer(@main, ["rev-parse", "HEAD"]), do: {head() <> "\n", 0}
  defp answer(@main, ["diff" | _]), do: {"", 0}
  defp answer(@main, ["merge", "--ff-only", @merged]), do: {"Fast-forward\n", 0}
  defp answer(cd, args), do: {"unscripted: git #{Enum.join(args, " ")} in #{cd}", 1}

  # `@base` when the promoting copy is checked against main and before the
  # merge, `@merged` after.
  defp head do
    reads = Process.put(:head_reads, Process.get(:head_reads, 0) + 1) || 0
    Enum.at([@base, @base], reads, @merged)
  end

  # Takes the restart and dies without answering: the acknowledgement is lost.
  defp an_app_that_drops_the_restart(working_copy_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = HarnessRegistry.register_executor(working_copy_id, "test-harness", @main)
        send(test, :registered)

        receive do
          {:"$gen_call", _from, {:restart_app, _request}} -> exit(:shutdown)
        end
      end)

    assert_receive :registered, 2_000
    pid
  end

  # The harness back after the drop, reporting what its app is serving.
  defp an_app_serving(working_copy_id, commit) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "test-harness", @main)
      send(test, :registered)
      answer_status(commit)
    end)

    assert_receive :registered, 2_000
  end

  defp answer_status(commit) do
    receive do
      {:"$gen_call", from, {:ensure_app_running, _request}} ->
        GenServer.reply(from, {:ok, %{status: "serving", url: "http://x", commit: commit}})
        answer_status(commit)
    end
  end

  defp promote_with_a_dropped_ack(serving_after) do
    scope = full_scope_fixture()

    {:ok, running} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, running} = WorkingCopies.report_root(running, @main)
    dropping = an_app_that_drops_the_restart(running.id)
    ref = Process.monitor(dropping)

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "agent", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, @agent)

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: @agent,
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    {:ok, env} = InMemoryEnvironment.create(shell: script())
    :ok = Environments.register({:working_copy, running.id}, env)
    :ok = Environments.register({:working_copy, copy.id}, env)
    scope = %{scope | active_working_copy_id: copy.id}

    story = story_fixture(scope, %{title: "Lost ack"})

    story
    |> Ecto.Changeset.change(qa_ready_commit: @merged, qa_ready_at: DateTime.utc_now())
    |> CodeMySpec.Repo.update!()

    {:ok, _} = passed_qa_attempt(scope, story_id: story.id)

    {_n, _} =
      Files.upsert_files(scope, [
        %{
          path: "test/spex/#{story.number}_x/criterion_1_spex.exs",
          role: :bdd_spec,
          story_id: story.id,
          valid: true,
          mtime: DateTime.utc_now()
        }
      ])

    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @merged)
    before = MapSet.new(Task.Supervisor.children(CodeMySpec.TaskSupervisor))

    assert {:ok, %{merged: "story/x"}} =
             Promotion.promote(scope, story.number,
               notify: agent.id,
               verify_within: verify_within(serving_after),
               verify_every: 20
             )

    assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 5_000
    told_after(running.id, agent.id, serving_after, before)
  end

  # Long enough that an app brought up after the dropped one's exit is still
  # asked on a loaded machine (a 1s window lost that race in the full run,
  # 2026-10-05). Merged ends polling at the first answer; an old commit is
  # reported failed when the window closes, so it stays well inside the wait.
  defp verify_within(nil), do: 1_000
  defp verify_within(@base), do: 5_000
  defp verify_within(_merged), do: 30_000

  # Nothing answering at all: nothing was learned, so nothing is told.
  defp told_after(_working_copy_id, _agent_id, nil, before) do
    await_own_tasks(before)
    nil
  end

  defp told_after(working_copy_id, agent_id, serving_after, before) do
    an_app_serving(working_copy_id, serving_after)
    assert_receive {:reported, ^agent_id, message}, 20_000
    await_own_tasks(before)
    message
  end

  # The restart task this promote started, not every task in the global
  # supervisor: another test's long-lived task is not this one's to wait for.
  defp await_own_tasks(before) do
    for pid <- Task.Supervisor.children(CodeMySpec.TaskSupervisor),
        not MapSet.member?(before, pid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 35_000
    end
  end

  test "the app reporting the merged commit confirms the restart as serving it" do
    message = promote_with_a_dropped_ack(@merged)

    assert message =~ "confirmed"
    assert message =~ "serving #{@merged}"
  end

  test "the app still on the old commit reports the restart failed, naming it" do
    message = promote_with_a_dropped_ack(@base)

    assert message =~ "restart failed: still on #{@base}"
    refute message =~ "confirmed"
  end

  # A restart nobody could be asked about is not a failed one: telling the
  # agent it failed sends it to fix a restart that may have worked.
  test "an app that never answers leaves the restart unconfirmed, not failed" do
    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert promote_with_a_dropped_ack(nil) == nil
      end)

    refute_received {:reported, _, _}
    assert log =~ "not confirmed: the app never answered"
    refute log =~ "restart FAILED"
  end
end
