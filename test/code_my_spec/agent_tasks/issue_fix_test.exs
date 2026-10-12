defmodule CodeMySpec.AgentTasks.IssueFixTest do
  @moduledoc """
  Completing `fix_issue` certifies the copy before QA, the way `ready_for_qa`
  does for a story (John, 2026-10-11): trusting the coder's own report, with
  no check that it even compiles, was an oversight rather than a deliberate
  choice.

  Git is scripted through the in-memory environment's shell; the copy's
  harness is a process that records the runs dispatched to it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.IssueFix
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Issues
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies

  @copy "/issue-fix/copy"
  @head "8888888888888888888888888888888888888888"

  defp script(status) do
    test = self()

    fn "git", args, opts ->
      send(test, {:git, Keyword.fetch!(opts, :cd), args})
      answer(status, args)
    end
  end

  defp answer(status, ["status" | _]), do: {status, 0}
  defp answer(_status, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"issue/x\n", 0}
  defp answer(_status, ["rev-parse", "HEAD"]), do: {@head <> "\n", 0}
  defp answer(_status, ["ls-files" | _]), do: {"", 0}
  defp answer(_status, args), do: {"unscripted: git #{Enum.join(args, " ")}", 1}

  defp a_harness(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "copy-harness", @copy)
      send(test, :registered)
      forward(test)
    end)

    assert_receive :registered, 2_000
  end

  defp forward(test) do
    receive do
      {:run_analysis, runs} -> send(test, {:dispatched, runs})
      _other -> :ok
    end

    forward(test)
  end

  defp a_copy(status \\ "") do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "copy", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, @copy)
    a_harness(copy.id)
    {:ok, env} = InMemoryEnvironment.create(shell: script(status))
    :ok = CodeMySpec.Environments.unregister({:working_copy, copy.id})
    :ok = CodeMySpec.Environments.register({:working_copy, copy.id}, env)
    scope = %{scope | active_working_copy_id: copy.id}
    %{scope: scope, issue: issue_fixture(scope, %{status: :accepted})}
  end

  defp task(issue), do: %{issue_id: issue.id}

  defp dispatched_sources do
    receive do
      {:dispatched, runs} -> Enum.map(runs, & &1["source"]) ++ dispatched_sources()
    after
      100 -> []
    end
  end

  defp stamp(scope, issue), do: Issues.get_issue(scope, issue.id).qa_ready_commit

  test "a dirty tree is refused, and nothing is stamped" do
    %{scope: scope, issue: issue} = a_copy(" M lib/war.ex\n")

    assert {:ok, :invalid, feedback} = IssueFix.evaluate(scope, task(issue), nil)
    assert feedback =~ "lib/war.ex"
    assert dispatched_sources() == []
    assert stamp(scope, issue) == nil
    assert Issues.get_issue(scope, issue.id).awaiting_role != :qa
  end

  test "with no run at HEAD, the gate starts every analyzer there and stays with coding" do
    %{scope: scope, issue: issue} = a_copy()

    assert {:ok, :pending, text} = IssueFix.evaluate(scope, task(issue), nil)
    assert text =~ @head
    assert Enum.sort(dispatched_sources()) == Enum.sort(Run.sources())
    assert stamp(scope, issue) == nil
    assert Issues.get_issue(scope, issue.id).awaiting_role != :qa
  end

  test "clean runs at HEAD certify that commit and hand the fix to QA" do
    %{scope: scope, issue: issue} = a_copy()
    AnalysisFixtures.fresh_analysis_runs_fixture(scope, Run.sources(), commit: @head)

    assert {:ok, :valid} = IssueFix.evaluate(scope, task(issue), nil)
    assert stamp(scope, issue) == @head
    assert Issues.get_issue(scope, issue.id).awaiting_role == :qa
    assert dispatched_sources() == [], "a certified commit's runs are reused, not restarted"
  end

  test "evaluate/2 reads the stamp and starts nothing" do
    %{scope: scope, issue: issue} = a_copy()

    assert {:ok, :invalid, _} = IssueFix.evaluate(scope, task(issue))
    assert dispatched_sources() == []

    {:ok, _} = Issues.set_qa_ready(scope, issue, @head)
    assert {:ok, :valid} = IssueFix.evaluate(scope, task(issue))
  end

  test "an already certified issue's task says there is nothing to do" do
    %{scope: scope, issue: issue} = a_copy()
    {:ok, _} = Issues.set_qa_ready(scope, issue, @head)

    assert {:ok, prompt} = IssueFix.command(scope, task(issue))
    assert prompt =~ "already certified ready for QA at #{@head}"
    assert prompt =~ "evaluate_task"
  end

  test "a missing issue cannot be certified" do
    scope = full_scope_fixture()
    missing = %{issue_id: Ecto.UUID.generate()}

    assert {:error, message} = IssueFix.evaluate(scope, missing, nil)
    assert message =~ "no longer exists"
  end
end
