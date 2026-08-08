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

  import CodeMySpec.ProblemsFixtures
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

  describe "adopting rows recorded before harnesses existed" do
    # The upgrade path. Files and problems written before they were grained by
    # working copy carry no harness, and a project whose rows belong to nobody
    # reads as empty — every requirement unsatisfied, the graph describing a
    # checkout that has all its files. The first harness to join adopts them,
    # because in the single-checkout case every install is in today, it *is* the
    # working copy they were scanned from.
    defp orphan_file(scope, path) do
      Files.upsert_files(scope, [
        %{path: path, role: :implementation, fingerprint: "f-#{path}"}
      ])

      Files.get_by_path(scope, path)
    end

    test "a pre-harness file is claimed by the first harness to join", %{scope: scope} do
      file = orphan_file(scope, "lib/legacy.ex")
      assert is_nil(file.harness_id), "rows written before the grain change own nothing"

      {:ok, harness} = Harnesses.issue(scope, nil, label: "the harness at /a")
      assert {1, _} = Files.adopt_orphans(scope, harness.id)

      assert Files.get_by_path(scope, "lib/legacy.ex").harness_id == harness.id
    end

    test "problems are adopted with the files they cite", %{scope: scope} do
      orphan_file(scope, "lib/legacy.ex")
      problem_fixture(scope, %{file_path: "lib/legacy.ex"})

      {:ok, harness} = Harnesses.issue(scope, nil, label: "the harness at /a")

      assert {1, _} = Files.adopt_orphans(scope, harness.id)

      assert {:ok, 1} = Problems.adopt_orphans(scope, harness.id),
             "a problem cites a file — adopting one without the other leaves a stop " <>
               "hook blocking on findings that belong to nothing"
    end

    test "adopting twice claims nothing the second time", %{scope: scope} do
      orphan_file(scope, "lib/legacy.ex")
      {:ok, harness} = Harnesses.issue(scope, nil, label: "the harness at /a")

      assert {1, _} = Files.adopt_orphans(scope, harness.id)

      assert {0, _} = Files.adopt_orphans(scope, harness.id),
             "every join runs this; it has to be a no-op after the first"
    end

    test "a second harness cannot take the first's files", %{scope: scope} do
      orphan_file(scope, "lib/legacy.ex")

      {:ok, first} = Harnesses.issue(scope, nil, label: "the harness at /a")
      {1, _} = Files.adopt_orphans(scope, first.id)

      {:ok, second} = Harnesses.issue(scope, nil, label: "the harness at /b")

      assert {0, _} = Files.adopt_orphans(scope, second.id),
             "adoption only ever claims unowned rows — a checkout taking another's " <>
               "files is the exact corruption this grain exists to prevent"

      assert Files.get_by_path(scope, "lib/legacy.ex").harness_id == first.id
    end

    test "another project's orphans are left alone", %{scope: scope} do
      other = full_scope_fixture()
      orphan_file(other, "lib/theirs.ex")
      orphan_file(scope, "lib/mine.ex")

      {:ok, harness} = Harnesses.issue(scope, nil, label: "the harness at /mine")

      assert {1, _} = Files.adopt_orphans(scope, harness.id)
      assert is_nil(Files.get_by_path(other, "lib/theirs.ex").harness_id)
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
