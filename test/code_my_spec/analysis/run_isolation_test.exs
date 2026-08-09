defmodule CodeMySpec.Analysis.RunIsolationTest do
  @moduledoc """
  Analysis runs belong to a working copy, not to a project.

  A worktree per branch is the ordinary case, and those checkouts are one
  project. Runs were scoped by `project_id` alone, so `fail_running/2` — which
  closes in-flight runs when a harness joins, on the reasoning that they
  belonged to a connection that has gone — closed every *other* checkout's runs
  too. Those analyzers then answered a row that was no longer `:running` and
  were told `unknown_run`.

  With more than one harness attached that is not a race but the steady state,
  because joins are frequent and a spex sweep takes minutes. Measured on one
  machine: 285 results sent, 0 accepted. `bdd_specs_passing` was unsatisfiable
  for every story in the project, since the only evidence that can satisfy it
  is an analyzer result and none could ever be recorded.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Harnesses

  # Two working copies of one project, as two scopes differing only by harness.
  defp two_checkouts do
    scope = full_scope_fixture()
    {:ok, other} = Harnesses.issue(scope, nil, label: "a second checkout")

    {scope, %{scope | active_harness_id: other.id}}
  end

  defp start(scope, source) do
    {:ok, run} = RunsRepository.start_run(scope, %{source: source, kind: :full})
    run
  end

  test "a join in one checkout does not fail another checkout's in-flight run" do
    {a, b} = two_checkouts()

    run_a = start(a, "spex")
    run_b = start(b, "spex")

    {:ok, count} = RunsRepository.fail_running(b, :harness_reconnected)

    assert count == 1, "only the joining harness's own run should have been closed"

    assert RunsRepository.get_running_run(a, run_a.id),
           "checkout A's spex sweep was still running and nothing about B's join " <>
             "says otherwise; failing it is how a 150s run comes back to " <>
             "`unknown_run` and is thrown away"

    refute RunsRepository.get_running_run(b, run_b.id)
  end

  test "a run is only visible to the checkout that owns it" do
    {a, b} = two_checkouts()

    run_a = start(a, "credo")

    assert RunsRepository.get_running_run(a, run_a.id)

    refute RunsRepository.get_running_run(b, run_a.id),
           "one checkout answering for another's run is how a result lands " <>
             "against the wrong tree"
  end

  test "recording a result against another checkout's run is refused" do
    {a, b} = two_checkouts()

    run_a = start(a, "credo")

    assert {:error, :unknown_run} =
             Analysis.record_remote_result(b, %{
               "run_id" => run_a.id,
               "source" => "credo",
               "status" => "ok",
               "result" => %{"diagnostics" => []}
             })
  end

  test "a checkout can record a result against its own run" do
    {a, _b} = two_checkouts()

    run = start(a, "credo")

    assert {:ok, _} =
             Analysis.record_remote_result(a, %{
               "run_id" => run.id,
               "source" => "credo",
               "status" => "ok",
               "result" => %{"diagnostics" => []}
             })
  end
end
