defmodule CodeMySpec.Problems.SupersededProblemsTest do
  @moduledoc """
  A finding stops being reported once its file provably changed.

  Reconciles replace problems per source per file, so a finding survives any
  run that does not re-examine its exact path — and is then reported against a
  file that moved underneath it. Observed as a credo finding at line 86 of an
  83-line file, presented as a current result rather than a stale one, with
  credo run by hand in the same working copy disagreeing.

  The rule is deliberately narrow: hide a finding only when both fingerprints
  are known and different. Everything else that went wrong in this subsystem
  went wrong by treating absent information as good news, so a missing
  fingerprint keeps the problem rather than dropping it.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Problems
  alias CodeMySpec.Repo

  @path "lib/thing.ex"

  defp file_at(scope, fingerprint) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      harness_id: scope.active_harness_id,
      path: @path,
      role: :implementation,
      fingerprint: fingerprint,
      size: 100,
      valid: true
    })
  end

  defp problem_at(scope, fingerprint) do
    Repo.insert!(%CodeMySpec.Problems.Problem{
      project_id: scope.active_project_id,
      harness_id: scope.active_harness_id,
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

  test "a finding whose file has changed is not reported" do
    scope = full_scope_fixture()
    file_at(scope, "sha-new")
    problem_at(scope, "sha-old")

    refute @path in paths(scope),
           "the file moved under this finding; reporting it as current sends an " <>
             "agent looking for line 86 of an 83-line file"
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
