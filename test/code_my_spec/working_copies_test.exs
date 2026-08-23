defmodule CodeMySpec.WorkingCopiesTest do
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
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Problems

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "issue/3" do
    test "a checkout that has never connected is minted one", %{scope: scope} do
      assert {:ok, harness} = WorkingCopies.issue(scope, nil, label: "the harness at /a")

      assert harness.project_id == scope.active_project_id
      assert harness.label == "the harness at /a"
      assert harness.last_seen_at
    end

    test "a checkout presenting its id is recognised, not minted again", %{scope: scope} do
      {:ok, first} = WorkingCopies.issue(scope, nil, label: "the harness at /a")

      assert {:ok, same} = WorkingCopies.issue(scope, first.id, label: "the harness at /a")

      assert same.id == first.id

      assert Enum.count(WorkingCopies.list_harnesses(scope), &(&1.id == first.id)) == 1,
             "recognising an id must not leave a second row behind"
    end

    test "two checkouts of one project are two harnesses", %{scope: scope} do
      {:ok, first} = WorkingCopies.issue(scope, nil, label: "the harness at /a")
      {:ok, second} = WorkingCopies.issue(scope, nil, label: "the harness at /b")

      refute first.id == second.id,
             "a checkout with no id has never been seen — sharing one with another " <>
               "checkout is the collision this grain exists to remove"

      ids = Enum.map(WorkingCopies.list_harnesses(scope), & &1.id)
      assert first.id in ids and second.id in ids
    end

    test "two checkouts with identical labels are still two harnesses", %{scope: scope} do
      # Two containers at /workspace/app on hosts with generated names produce
      # the same string. That collision is exactly why the label is display only
      # and the id is issued.
      {:ok, first} = WorkingCopies.issue(scope, nil, label: "the harness at /workspace/app")
      {:ok, second} = WorkingCopies.issue(scope, nil, label: "the harness at /workspace/app")

      refute first.id == second.id
    end

    test "an id naming no harness is reissued rather than refused", %{scope: scope} do
      stale = Ecto.UUID.generate()

      assert {:ok, harness} = WorkingCopies.issue(scope, stale, label: "the harness at /a")

      refute harness.id == stale,
             "a row deleted under a working copy that still holds the file must not " <>
               "leave that copy unable to serve until somebody finds and deletes it"
    end

    test "a malformed id is reissued rather than crashing the join", %{scope: scope} do
      assert {:ok, harness} = WorkingCopies.issue(scope, "not-a-uuid", label: "the harness at /a")
      assert harness.id
    end

    test "an id belonging to another project does not resolve", %{scope: scope} do
      other = full_scope_fixture()
      {:ok, theirs} = WorkingCopies.issue(other, nil, label: "the harness at /theirs")

      assert {:ok, mine} = WorkingCopies.issue(scope, theirs.id, label: "the harness at /mine")

      refute mine.id == theirs.id,
             "a misconfigured checkout must not adopt a harness belonging to a " <>
               "project it has nothing to do with"

      assert mine.project_id == scope.active_project_id
    end

    test "rejoining refreshes the label, because a checkout can move", %{scope: scope} do
      {:ok, first} = WorkingCopies.issue(scope, nil, label: "the harness at /old")

      {:ok, same} = WorkingCopies.issue(scope, first.id, label: "the harness at /new")

      assert same.id == first.id
      assert same.label == "the harness at /new"
    end

    test "a join carrying no label leaves the last known one alone", %{scope: scope} do
      {:ok, first} = WorkingCopies.issue(scope, nil, label: "the harness at /a")

      {:ok, same} = WorkingCopies.issue(scope, first.id)

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
      {:ok, harness} = WorkingCopies.issue(scope, nil, label: label)
      %{scope | active_working_copy_id: harness.id}
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
      |> Enum.filter(&(&1.working_copy_id == scope.active_working_copy_id))
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
               "(project_id, working_copy_id, path) is what makes that expressible — under " <>
               "the old (project_id, path) b's upsert conflicted onto a's row and b " <>
               "appeared to have no such file"
    end

    test "each reads only its own files", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      sync(a, ["lib/shared.ex", "lib/only_in_a.ex"])
      sync(b, ["lib/shared.ex"])

      assert Enum.map(Files.list_files(a), & &1.path) |> Enum.sort() ==
               ["lib/only_in_a.ex", "lib/shared.ex"]

      assert Enum.map(Files.list_files(b), & &1.path) == ["lib/shared.ex"],
             "scoping the writes without the reads would show b every file in the " <>
               "project, including two rows for the path both checkouts hold"
    end

    test "a shared path resolves to one file per checkout", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      sync(a, ["lib/shared.ex"])
      sync(b, ["lib/shared.ex"])

      # `Repo.one/1` raises on two rows, so an unscoped read here was not merely
      # noisy — it crashed the moment a second checkout held the same path.
      assert Files.get_by_path(a, "lib/shared.ex").working_copy_id == a.active_working_copy_id
      assert Files.get_by_path(b, "lib/shared.ex").working_copy_id == b.active_working_copy_id
    end

    test "a scope holding no harness still reconciles the whole project", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      sync(a, ["lib/a.ex"])

      # A caller holding the project rather than one copy of it — a mix task, the
      # web UI. Those still exist, and unscoped is the honest behaviour for them:
      # they are asking about the project, not about a checkout of it.
      {deleted, _} = Files.delete_removed(%{scope | active_working_copy_id: nil}, [])

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
      |> Enum.filter(&(&1.working_copy_id == scope.active_working_copy_id))
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

  describe "authored work is shared, observed work is not" do
    # Criterion 734, and the line the whole grain is drawn along. Stories,
    # criteria, rules, personas, epics and components are *authored* — one team
    # writing one design — so every checkout sees the same set. Files and
    # problems are *observed*, so they belong to the checkout that saw them.
    #
    # It holds because authored tables have no working_copy_id at all rather than
    # because anything remembers to skip the filter, which is the version that
    # cannot rot.
    test "a story authored through one checkout is visible from the other", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      {:ok, story} =
        CodeMySpec.Stories.create_story(a, %{
          title: "Authored from a",
          description: "Belongs to the project, not the checkout"
        })

      titles = b |> CodeMySpec.Stories.list_stories() |> Enum.map(& &1.title)

      assert story.title in titles,
             "authored work is the project's; a checkout that cannot see it would " <>
               "be working from a different design"
    end

    test "components are shared while the files projecting them are not", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      component = CodeMySpec.ComponentsFixtures.component_fixture(a)

      assert component.id in Enum.map(CodeMySpec.Components.list_components(b), & &1.id),
             "components carry no harness — they are design, and story 727's " <>
               "earlier 'components follow files' decision was dropped for this reason"

      sync(a, ["lib/a_only.ex"])
      assert Files.list_files(b) == []
    end
  end

  describe "the operator's view" do
    test "the most recently active harness is the default", %{scope: scope} do
      {:ok, first} = WorkingCopies.issue(scope, nil, label: "the harness at /a")
      {:ok, second} = WorkingCopies.issue(scope, nil, label: "the harness at /b")

      assert WorkingCopies.most_recent(scope).id == second.id,
             "criterion 739 — no configuration needed, and it stays correct for a " <>
               "checkout nobody thought to classify"

      assert first.id in Enum.map(WorkingCopies.list_harnesses(scope), & &1.id),
             "the operator can still switch to the other one"
    end

    test "a page reads as the most recently active checkout", %{scope: scope} do
      a = harness_scope(scope, "the harness at /a")
      b = harness_scope(scope, "the harness at /b")

      sync(a, ["lib/only_in_a.ex"])
      sync(b, ["lib/only_in_b.ex"])

      viewing = WorkingCopies.viewing(scope)

      assert viewing.active_working_copy_id == b.active_working_copy_id

      assert Enum.map(Files.list_files(viewing), & &1.path) == ["lib/only_in_b.ex"],
             "a project-wide scope would list both checkouts' files with nothing " <>
               "saying which is which"
    end

    test "a project with nothing synced stays project-wide" do
      bare = full_scope_fixture()
      # The fixture mints one, so drop it to get the genuinely-never-synced case.
      bare = %{bare | active_working_copy_id: nil}

      assert WorkingCopies.viewing(%{bare | active_project_id: Ecto.UUID.generate()}).active_working_copy_id ==
               nil
    end

    test "a project with no harness has no default" do
      # Deliberately not `full_scope_fixture/0` — that mints one, because a
      # scope that writes files needs one. This is the genuinely empty case.
      bare = user_scope_fixture(user_fixture(), account_fixture())

      assert WorkingCopies.list_harnesses(%{bare | active_project_id: Ecto.UUID.generate()}) == []
    end

    test "another project's harnesses are not listed", %{scope: scope} do
      other = full_scope_fixture()
      {:ok, theirs} = WorkingCopies.issue(other, nil, label: "the harness at /theirs")
      {:ok, mine} = WorkingCopies.issue(scope, nil, label: "the harness at /mine")

      ids = Enum.map(WorkingCopies.list_harnesses(scope), & &1.id)
      assert mine.id in ids
      refute theirs.id in ids
    end
  end
end
