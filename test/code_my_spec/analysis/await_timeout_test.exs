defmodule CodeMySpec.Analysis.AwaitTimeoutTest do
  @moduledoc """
  Running out of time is not the same answer as finishing.

  `await_all/2` returned `:ok` on both, so every caller read "I gave up waiting"
  as "the analyzers finished". `await_analysis` then reported "Analysis
  complete" over a queue that was still running — the single thing an agent
  calls that tool to rule out.

  It could not be observed from outside either: the tool waited 20 minutes while
  the MCP transport gives up at 30s, so the call died with
  `-32603 Server unavailable` before any answer came back. A wrong answer hidden
  behind an unrelated-looking outage.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Repo

  defp running_run(scope) do
    Repo.insert!(%Run{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      source: "exunit",
      kind: :full,
      status: :running,
      started_at: DateTime.utc_now()
    })
  end

  # `in_flight/1` reads the run ledger only when a harness is serving the
  # project — otherwise it asks a local ProjectServer that does not exist here
  # and gets `[]`. Registering this process as the executor is what makes the
  # inserted run visible, and it is the shape the tool actually runs in.
  defp serving(scope) do
    {:ok, _} =
      Registry.register(
        CodeMySpec.Analysis.HarnessRegistry,
        to_string(scope.active_working_copy_id),
        :test
      )

    scope
  end

  test "a project with nothing in flight returns :ok" do
    scope = full_scope_fixture() |> serving()

    assert :ok = Analysis.await_all(scope, timeout: 50)
  end

  test "giving up while a run is still going returns :timeout, not :ok" do
    scope = full_scope_fixture() |> serving()
    running_run(scope)

    assert :timeout = Analysis.await_all(scope, timeout: 50),
           "a caller cannot tell 'finished' from 'gave up' if both are :ok, and " <>
             "await_analysis reports 'Analysis complete' on the strength of it"
  end

  # Promotion's gate passes this by default now (376e3356): it is already
  # async, so a deadline here has no caller to protect, only a real answer to
  # delay into a wrong one.
  describe "timeout: :infinity" do
    test "keeps waiting past a deadline that would otherwise have lapsed" do
      scope = full_scope_fixture() |> serving()
      run = running_run(scope)

      task = Task.async(fn -> Analysis.await_all(scope, timeout: :infinity) end)

      # Long enough that a finite deadline in this range would already have
      # given up — proving this one has not, rather than merely not yet
      # having reached whatever it is bounded by.
      assert Task.yield(task, 300) == nil,
             "an :infinity wait answered before the run it was waiting on finished"

      Repo.update!(Ecto.Changeset.change(run, status: :completed))

      assert Task.await(task, 2_000) == :ok
    end

    test "still returns :ok immediately when nothing is in flight" do
      scope = full_scope_fixture() |> serving()

      assert :ok = Analysis.await_all(scope, timeout: :infinity)
    end
  end
end
