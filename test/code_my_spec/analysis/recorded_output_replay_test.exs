defmodule CodeMySpec.Analysis.RecordedOutputReplayTest do
  # Sync: `Local` is meck'd VM-wide to prove nothing reaches it.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.{Execution, RunsRepository}
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Local
  alias CodeMySpec.Support.InMemoryEnvironment

  @cwd "/memfs/recorded-replay"
  @spex_green Path.expand("test/fixtures/validation/spex_green.jsonl")
  @exunit_failure Path.expand("test/fixtures/validation/pipeline_exunit_failure/exunit.json")

  setup do
    :meck.new(Local, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Local) end)

    {:ok, env} = InMemoryEnvironment.create(working_dir: @cwd)
    on_exit(fn -> InMemoryEnvironment.destroy(env) end)

    %{scope: %{full_scope_fixture() | cwd: @cwd}, env: env}
  end

  defp run(scope, env, source) do
    scope = %{scope | environment: env}
    {:ok, run} = RunsRepository.start_run(scope, %{source: source, kind: :full, args: %{}})
    Execution.execute(scope, run)
  end

  # Calls that reached the real shell from this test's environment.
  defp local_calls do
    Local
    |> :meck.history()
    |> Enum.count(&match?({Local, :cmd, [%{cwd: @cwd} | _]}, elem(&1, 1)))
  end

  test "a spex run replays the output attached to the environment", %{scope: scope, env: env} do
    env = InMemoryEnvironment.record_output(env, "spex", @spex_green)

    assert {:ok, %{status: :completed, exit_status: 0}} = run(scope, env, "spex")
    assert local_calls() == 0
  end

  test "an exunit run replays the attached results without a subprocess",
       %{scope: scope, env: env} do
    env = InMemoryEnvironment.record_output(env, "exunit", @exunit_failure)

    assert {:ok, %{status: :completed, exit_status: 2}} = run(scope, env, "exunit")
    assert local_calls() == 0
  end

  test "an analyzer with nothing recorded is refused, not run", %{scope: scope, env: env} do
    assert {message, 1} = Environments.cmd(env, "mix", ["spex", "--jsonl=x"])
    assert message =~ "no recorded analyzer output for spex"

    assert {:error, {:spex_suite_did_not_run, 1, ^message}} = run(scope, env, "spex")
    assert local_calls() == 0
  end

  test "non-analyzer commands still run", %{env: env} do
    assert {"hi\n", 0} = Environments.cmd(env, "echo", ["hi"], cd: System.tmp_dir!())
    assert local_calls() == 1
  end
end
