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

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.Harnesses

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
      assert length(Harnesses.list_harnesses(scope)) == 1
    end

    test "two checkouts of one project are two harnesses", %{scope: scope} do
      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /a")
      {:ok, second} = Harnesses.issue(scope, nil, label: "the harness at /b")

      refute first.id == second.id,
             "a checkout with no id has never been seen — sharing one with another " <>
               "checkout is the collision this grain exists to remove"

      assert length(Harnesses.list_harnesses(scope)) == 2
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

    # The half that is not done, stated as a test so it is not a surprise later.
    #
    # `files` carries UNIQUE (project_id, path). Two checkouts therefore cannot
    # both hold a row for one path: b's upsert conflicts onto a's row and updates
    # it, and `harness_id` is not in the `on_conflict` replace list, so the row
    # stays a's. Scoping the queries was necessary and is not sufficient — the
    # *storage* is still project-grained.
    #
    # Fixing it means the unique index includes `harness_id`, which means
    # `conflict_target` does too, which means `harness_id` cannot be null (ON
    # CONFLICT never matches a null, so every upsert would insert a duplicate).
    # That in turn means every sync path needs a harness, including the local
    # CLI one that has no channel and no notion of one today. That is a decision,
    # not a refactor.
    test "a path shared by both checkouts still resolves to one row", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      sync(a, ["lib/shared.ex"])
      sync(b, ["lib/shared.ex"])

      assert paths_of(a) == ["lib/shared.ex"]

      assert paths_of(b) == [],
             "b's copy of lib/shared.ex conflicted onto a's row. When UNIQUE " <>
               "(project_id, path) grows harness_id this becomes [\"lib/shared.ex\"] " <>
               "and this assertion should flip"
    end

    test "resyncing one does not disturb the other", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      sync(a, ["lib/a_one.ex", "lib/a_two.ex"])
      sync(b, ["lib/b_one.ex"])

      # a deletes a file and rescans — the classic case that used to take b's
      # files with it.
      sync(a, ["lib/a_one.ex"])

      assert paths_of(a) == ["lib/a_one.ex"]
      assert paths_of(b) == ["lib/b_one.ex"], "b never scanned; nothing of b's should have moved"
    end

    test "a scope holding no harness still reconciles the whole project", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      sync(a, ["lib/a.ex"])

      # A caller holding the project rather than one copy of it — a mix task, the
      # web UI. Unscoped is the honest behaviour there, and it is why the harness
      # has to be on the scope rather than passed per call.
      {deleted, _} = Files.delete_removed(scope, [])

      assert deleted == 1
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

    test "a project with no harness has no default", %{scope: scope} do
      assert Harnesses.most_recent(scope) == nil
      assert Harnesses.list_harnesses(scope) == []
    end

    test "another project's harnesses are not listed", %{scope: scope} do
      other = full_scope_fixture()
      {:ok, _theirs} = Harnesses.issue(other, nil, label: "the harness at /theirs")
      {:ok, mine} = Harnesses.issue(scope, nil, label: "the harness at /mine")

      assert Enum.map(Harnesses.list_harnesses(scope), & &1.id) == [mine.id]
    end
  end
end
