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
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Files
  alias CodeMySpec.Promotion
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies
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

    # The outcome is messaged from the detached restart task.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    :ok
  end

  # A fast-forward from `@base` to `@merged`.
  defp script do
    fn "git", args, opts -> answer(Keyword.fetch!(opts, :cd), args) end
  end

  defp answer(@agent, ["status" | _]), do: {"", 0}
  defp answer(@agent, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"story/x\n", 0}
  defp answer(@agent, ["ls-files" | _]), do: {"", 0}
  defp answer(@main, ["rev-parse", "HEAD"]), do: {head() <> "\n", 0}
  defp answer(@main, ["diff" | _]), do: {"", 0}
  defp answer(@main, ["merge", "--ff-only", "story/x"]), do: {"Fast-forward\n", 0}
  defp answer(cd, args), do: {"unscripted: git #{Enum.join(args, " ")} in #{cd}", 1}

  defp head do
    reads = Process.put(:head_reads, Process.get(:head_reads, 0) + 1) || 0
    Enum.at([@base], reads, @merged)
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

    {:ok, env} = InMemoryEnvironment.create(shell: script())
    scope = %{scope | active_working_copy_id: copy.id, environment: env}

    story = story_fixture(scope, %{title: "Lost ack"})

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

    AnalysisFixtures.fresh_analysis_runs_fixture(scope)
    AnalysisFixtures.fresh_analysis_runs_fixture(%{scope | active_working_copy_id: running.id})

    assert {:ok, %{merged: "story/x"}} =
             Promotion.promote(scope, story.number,
               notify: agent.id,
               verify_within: 1_000,
               verify_every: 20
             )

    assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 5_000
    an_app_serving(running.id, serving_after)

    agent_id = agent.id
    assert_receive {:agent_dispatch, ^agent_id, _ref, message}, 10_000
    await_restart_tasks()
    message
  end

  # The message is sent before the task that sent it ends.
  defp await_restart_tasks do
    for pid <- Task.Supervisor.children(CodeMySpec.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
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
end
