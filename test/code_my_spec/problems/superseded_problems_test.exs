defmodule CodeMySpec.Problems.SupersededProblemsTest do
  @moduledoc """
  A finding stops being reported once the analyzer has re-examined its file.

  Reconciles replace problems per source per file, so a finding survives any
  run that does not re-examine its exact path — and is then reported against a
  file that moved underneath it. Observed as a credo finding at line 86 of an
  83-line file, presented as a current result rather than a stale one, with
  credo run by hand in the same working copy disagreeing.

  The first fix hid a finding as soon as its file's fingerprint moved on. That
  went too far in the other direction: the edit alone retired the finding, so
  touching a file cleared the gate before any analyzer had looked at the new
  content — story 988, criterion 8201. Both halves of that are bad in the same
  way, one showing a finding that is no longer true and one hiding one that
  still is.

  So the rule now needs both: the fingerprint differs *and* a completed run for
  that source finished after the file changed. The cost is accepted
  deliberately — between the edit and the rerun a finding can still point at
  line 86 of an 83-line file, and sweeps here run minutes. The alternative is a
  gate an agent can clear by touching the file.

  The rule stays narrow in the same direction as before: absent information
  keeps the problem. No fingerprint, no mtime, no File row at all — the finding
  is reported rather than dropped, because everything else that went wrong in
  this subsystem went wrong by treating absent information as good news.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Problems
  alias CodeMySpec.Repo

  @path "lib/thing.ex"

  @changed_at ~U[2026-08-10 12:00:00.000000Z]

  defp file_at(scope, fingerprint, mtime \\ @changed_at) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: @path,
      role: :implementation,
      fingerprint: fingerprint,
      mtime: mtime,
      size: 100,
      valid: true
    })
  end

  # A completed credo run, `seconds` after the file changed. Negative means it
  # finished before the change and therefore says nothing about the new content.
  defp credo_run(scope, seconds) do
    Repo.insert!(%CodeMySpec.Analysis.Run{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      source: "credo",
      kind: :full,
      status: :completed,
      started_at: @changed_at,
      finished_at: DateTime.add(@changed_at, seconds, :second)
    })
  end

  defp problem_at(scope, fingerprint) do
    Repo.insert!(%CodeMySpec.Problems.Problem{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      file_path: @path,
      file_fingerprint: fingerprint,
      line: 86,
      severity: :warning,
      source_type: :static_analysis,
      source: "credo",
      category: "readability",
      message: "Imperative `if` is not allowed"
    })
  end

  defp paths(scope), do: scope |> Problems.list_project_problems([]) |> Enum.map(& &1.file_path)

  test "a finding whose file has changed still blocks until the rerun lands" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new")
    problem_at(scope, "sha-old")

    assert @path in paths(scope),
           "the edit alone retired the finding — an agent clears the gate by " <>
             "touching the file, which is story 988's criterion 8201"
  end

  test "a finding is retired once a run for its source lands on the new content" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new")
    problem_at(scope, "sha-old")
    credo_run(scope, 60)

    refute @path in paths(scope),
           "credo has now run against the changed file and did not re-report " <>
             "this, so reporting it sends an agent looking for line 86 of an " <>
             "83-line file"
  end

  test "a run that finished before the change does not retire the finding" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new")
    problem_at(scope, "sha-old")
    credo_run(scope, -60)

    assert @path in paths(scope),
           "that run examined the old content, so it is not the replacement run"
  end

  test "a run for a different source does not retire the finding" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new")
    problem_at(scope, "sha-old")

    Repo.insert!(%CodeMySpec.Analysis.Run{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      source: "exunit",
      kind: :full,
      status: :completed,
      started_at: @changed_at,
      finished_at: DateTime.add(@changed_at, 60, :second)
    })

    assert @path in paths(scope),
           "exunit finishing says nothing about whether credo still objects"
  end

  test "a run still running does not retire the finding" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new")
    problem_at(scope, "sha-old")

    Repo.insert!(%CodeMySpec.Analysis.Run{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      source: "credo",
      kind: :full,
      status: :running,
      started_at: DateTime.add(@changed_at, 30, :second)
    })

    assert @path in paths(scope),
           "the rerun has not landed yet — that is the whole window 8201 is about"
  end

  test "a file with no mtime keeps the finding" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new", nil)
    problem_at(scope, "sha-old")
    credo_run(scope, 60)

    assert @path in paths(scope),
           "nothing says when the file changed, so nothing says the run saw it"
  end

  test "a finding whose file is unchanged is still reported" do
    scope = full_scope_fixture()
    file_at(scope, "sha-same")
    problem_at(scope, "sha-same")

    assert @path in paths(scope)
  end

  test "a finding recorded before fingerprints existed is kept" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new")
    problem_at(scope, nil)

    assert @path in paths(scope),
           "nothing is known about which version this described, and hiding a " <>
             "real finding is worse than showing an old one"
  end

  test "a finding whose file the manifest has never seen is kept" do
    scope = full_scope_fixture()
    problem_at(scope, "sha-old")

    assert @path in paths(scope)
  end
end
