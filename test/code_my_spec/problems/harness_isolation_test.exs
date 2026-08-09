defmodule CodeMySpec.Problems.HarnessIsolationTest do
  @moduledoc """
  What a scope that names no working copy means.

  It has to mean the same thing on the way in and on the way out. It did not:
  `insert_all_problems/2` sent such writes to the project's default harness,
  while the read and clear predicate treated nil as *every* harness. Since
  `clear_problems_for_source/3` shares that predicate, one checkout reconciling
  a source under a nameless scope deleted every other checkout's problems for
  it.

  That is expensive to recognise because the damage does not look like
  deletion. Afterwards a harness-scoped read returns nothing while an unscoped
  one still shows a live project-wide count — so the stop hook's blocking set
  and its advisory count describe different populations inside one response,
  and the findings it blocks on name files whose rows are gone.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Harnesses
  alias CodeMySpec.Problems.ProblemRepository

  defp problem(path) do
    %{
      source: "credo",
      source_type: :static_analysis,
      severity: :info,
      file_path: path,
      line: 1,
      message: "m",
      category: "c"
    }
  end

  defp reconcile(scope, problems),
    do: ProblemRepository.reconcile_problems_for_source(scope, "credo", :all, problems)

  defp paths(scope) do
    scope
    |> ProblemRepository.list_project_problems(source: "credo")
    |> Enum.map(& &1.file_path)
    |> Enum.sort()
  end

  setup do
    scope = full_scope_fixture()
    {:ok, a} = Harnesses.issue(scope, nil, label: "copy A")
    {:ok, b} = Harnesses.issue(scope, nil, label: "copy B")

    %{
      scope: scope,
      a: %{scope | active_harness_id: a.id},
      b: %{scope | active_harness_id: b.id},
      nameless: %{scope | active_harness_id: nil}
    }
  end

  test "two working copies keep their own findings", %{a: a, b: b} do
    {:ok, _} = reconcile(a, [problem("lib/a.ex")])
    {:ok, _} = reconcile(b, [problem("lib/b.ex")])

    assert paths(a) == ["lib/a.ex"]
    assert paths(b) == ["lib/b.ex"]
  end

  # The defect, stated as the thing that must not happen. A reconcile is
  # "replace this source's findings for this working copy", and a scope that
  # cannot name one must not be read as licence to replace everybody's.
  test "a reconcile under a nameless scope leaves other copies alone",
       %{a: a, b: b, nameless: nameless} do
    {:ok, _} = reconcile(a, [problem("lib/a.ex")])
    {:ok, _} = reconcile(b, [problem("lib/b.ex")])

    {:ok, _} = reconcile(nameless, [problem("lib/n.ex")])

    assert paths(a) == ["lib/a.ex"],
           "one checkout's analysis run deleted another checkout's findings"

    assert paths(b) == ["lib/b.ex"],
           "one checkout's analysis run deleted another checkout's findings"
  end

  # The other half of the symmetry: writes with no harness already landed on the
  # project's default working copy, so reads with no harness have to find them.
  # Otherwise a nameless writer files problems nothing can ever see or clear.
  test "a nameless scope reads back exactly what it wrote", %{nameless: nameless} do
    {:ok, _} = reconcile(nameless, [problem("lib/n.ex")])

    assert paths(nameless) == ["lib/n.ex"]
  end

  test "a nameless scope does not see another copy's findings", %{a: a, nameless: nameless} do
    {:ok, _} = reconcile(a, [problem("lib/a.ex")])

    refute "lib/a.ex" in paths(nameless),
           "blocking a stop on a finding from a checkout this session is not in " <>
             "is unresolvable from here — the file it names may not even be on this disk"
  end
end
