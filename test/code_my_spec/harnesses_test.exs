defmodule CodeMySpec.HarnessesTest do
  @moduledoc """
  Which working copies a project has, and how each one gets its identity.

  Story 727. Files and problems are projections of a working copy but have only
  ever been keyed by project, so two checkouts write the same rows and each
  sync deletes what the other just wrote. A harness is the grain that fixes it.

  The identity is issued here rather than derived on the client because every
  client-derived alternative collides on a real case: two containers both at
  `/workspace/app`, a container hostname that is generated, a session id that
  churns. The case that settles it is a local agent and a cloud agent on one
  branch — same path, different machines, different uncommitted state.

  So the rules under test are all one rule: **an id is never invented by the
  client and never silently replaced.**
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.Harnesses
  alias CodeMySpec.Problems

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "issue/3" do
    test "a checkout that has never connected is minted one", %{scope: scope} do
      assert {:ok, harness} = Harnesses.issue(scope, nil, label: "the harness at /a")

      assert harness.project_id == scope.active_project_id
      assert harness.label == "the harness at /a"
      assert harness.last_seen_at
    end

    test "a checkout presenting its id is recognised, not minted again", %{scope: scope} do
      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /a")

      assert {:ok, same} = Harnesses.issue(scope, first.id, label: "the harness at /a")

      assert same.id == first.id

      assert Enum.count(Harnesses.list_harnesses(scope), &(&1.id == first.id)) == 1,
             "recognising an id must not leave a second row behind"
    end

    test "two checkouts of one project are two harnesses", %{scope: scope} do
      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /a")
      {:ok, second} = Harnesses.issue(scope, nil, label: "the harness at /b")

      refute first.id == second.id,
             "a checkout with no id has never been seen — sharing one with another " <>
               "checkout is the collision this grain exists to remove"

      ids = Enum.map(Harnesses.list_harnesses(scope), & &1.id)
      assert first.id in ids and second.id in ids
    end

    test "two checkouts with identical labels are still two harnesses", %{scope: scope} do
      # Two containers at /workspace/app on hosts with generated names produce
      # the same string. That collision is exactly why the label is display only
      # and the id is issued.
      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /workspace/app")
      {:ok, second} = Harnesses.issue(scope, nil, label: "the harness at /workspace/app")

      refute first.id == second.id
    end

    test "an id naming no harness is reissued rather than refused", %{scope: scope} do
      stale = Ecto.UUID.generate()

      assert {:ok, harness} = Harnesses.issue(scope, stale, label: "the harness at /a")

      refute harness.id == stale,
             "a row deleted under a working copy that still holds the file must not " <>
               "leave that copy unable to serve until somebody finds and deletes it"
    end

    test "a malformed id is reissued rather than crashing the join", %{scope: scope} do
      assert {:ok, harness} = Harnesses.issue(scope, "not-a-uuid", label: "the harness at /a")
      assert harness.id
    end

    test "an id belonging to another project does not resolve", %{scope: scope} do
      other = full_scope_fixture()
      {:ok, theirs} = Harnesses.issue(other, nil, label: "the harness at /theirs")

      assert {:ok, mine} = Harnesses.issue(scope, theirs.id, label: "the harness at /mine")

      refute mine.id == theirs.id,
             "a misconfigured checkout must not adopt a harness belonging to a " <>
               "project it has nothing to do with"

      assert mine.project_id == scope.active_project_id
    end

    test "rejoining refreshes the label, because a checkout can move", %{scope: scope} do
      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /old")

      {:ok, same} = Harnesses.issue(scope, first.id, label: "the harness at /new")

      assert same.id == first.id
      assert same.label == "the harness at /new"
    end

    test "a join carrying no label leaves the last known one alone", %{scope: scope} do
      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /a")

      {:ok, same} = Harnesses.issue(scope, first.id)

      assert same.label == "the harness at /a",
             "losing the only human-readable name for a checkout would leave a " <>
               "refusal unable to say which one to go and stop"
    end
  end

  describe "two working copies of one project" do
    # The thing the grain exists for. `FileSync.reconcile/2` is a *full*
    # reconcile: it deletes whatever the scan did not see. Keyed only by
    # project, that meant each checkout's sync erased the other's files, so the
    # requirement graph — computed from those rows — described neither.
    defp harness_scope(scope, label) do
      {:ok, harness} = Harnesses.issue(scope, nil, label: label)
      %{scope | active_harness_id: harness.id}
    end

    defp sync(scope, paths) do
      Files.upsert_files(
        scope,
        Enum.map(paths, &%{path: &1, role: :implementation, fingerprint: "f-#{&1}"})
      )

      Files.delete_removed(scope, paths)
    end

    defp paths_of(scope) do
      scope
      |> Files.list_files()
      |> Enum.filter(&(&1.harness_id == scope.active_harness_id))
      |> Enum.map(& &1.path)
      |> Enum.sort()
    end

    test "a file only one of them has survives the other's sync", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      sync(a, ["lib/only_in_a.ex"])
      sync(b, ["lib/only_in_b.ex"])

      assert paths_of(a) == ["lib/only_in_a.ex"],
             "b's full reconcile must not delete a file a still has on disk"

      assert paths_of(b) == ["lib/only_in_b.ex"]
    end

    test "both checkouts hold their own copy of a shared path", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      sync(a, ["lib/shared.ex"])
      sync(b, ["lib/shared.ex"])

      assert paths_of(a) == ["lib/shared.ex"]

      assert paths_of(b) == ["lib/shared.ex"],
             "the same path in two checkouts is two files. UNIQUE " <>
               "(project_id, harness_id, path) is what makes that expressible — under " <>
               "the old (project_id, path) b's upsert conflicted onto a's row and b " <>
               "appeared to have no such file"
    end

    test "a scope holding no harness still reconciles the whole project", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      sync(a, ["lib/a.ex"])

      # A caller holding the project rather than one copy of it — a mix task, the
      # web UI. Those still exist, and unscoped is the honest behaviour for them:
      # they are asking about the project, not about a checkout of it.
      {deleted, _} = Files.delete_removed(%{scope | active_harness_id: nil}, [])

      assert deleted == 1
    end
  end

  describe "two working copies' problems" do
    # Criterion 732: "that failure appears only in that agent's problems, and the
    # other agent's stop hook reports nothing about it." A reconcile is a
    # wipe-and-replace for one source, so unscoped it had the same shape as the
    # file corruption — one checkout's analyzer run cleared the other's findings.
    defp problems_of(scope, source) do
      scope
      |> Problems.list_project_problems(source: source)
      |> Enum.filter(&(&1.harness_id == scope.active_harness_id))
      |> Enum.map(& &1.message)
      |> Enum.sort()
    end

    defp record(scope, source, message) do
      {:ok, _} =
        Problems.reconcile_problems_for_source(scope, source, :all, [
          %{
            severity: :error,
            source_type: :test,
            source: source,
            file_path: "test/a_test.exs",
            message: message,
            category: "failure"
          }
        ])
    end

    test "a failure found in one checkout is not reported in the other", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      record(a, "exunit", "a's test is broken")

      assert problems_of(a, "exunit") == ["a's test is broken"]

      assert problems_of(b, "exunit") == [],
             "b never ran that analyzer — its stop hook must report nothing about it"
    end

    test "a clean run in one checkout does not clear the other's findings", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      record(a, "exunit", "a's test is broken")

      # b's suite passes: a full reconcile for exunit with nothing to report.
      {:ok, []} = Problems.reconcile_problems_for_source(b, "exunit", :all, [])

      assert problems_of(a, "exunit") == ["a's test is broken"],
             "a is still broken; b passing says nothing about a's checkout"
    end
  end

  describe "the operator's view" do
    test "the most recently active harness is the default", %{scope: scope} do
      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /a")
      {:ok, second} = Harnesses.issue(scope, nil, label: "the harness at /b")

      assert Harnesses.most_recent(scope).id == second.id,
             "criterion 739 — no configuration needed, and it stays correct for a " <>
               "checkout nobody thought to classify"

      assert first.id in Enum.map(Harnesses.list_harnesses(scope), & &1.id),
             "the operator can still switch to the other one"
    end

    test "a project with no harness has no default" do
      # Deliberately not `full_scope_fixture/0` — that mints one, because a
      # scope that writes files needs one. This is the genuinely empty case.
      bare = user_scope_fixture(user_fixture(), account_fixture())

      assert Harnesses.list_harnesses(%{bare | active_project_id: Ecto.UUID.generate()}) == []
    end

    test "another project's harnesses are not listed", %{scope: scope} do
      other = full_scope_fixture()
      {:ok, theirs} = Harnesses.issue(other, nil, label: "the harness at /theirs")
      {:ok, mine} = Harnesses.issue(scope, nil, label: "the harness at /mine")

      ids = Enum.map(Harnesses.list_harnesses(scope), & &1.id)
      assert mine.id in ids
      refute theirs.id in ids
    end
  end
end
