defmodule CodeMySpec.Requirements.OrphansArePerWorkingCopyTest do
  @moduledoc """
  An orphan belongs to the checkout that has the file, not to every checkout.

  Components are project-level and their ids are stable — 112 stories and 4048
  requirements link to them, so they must be. Presence is the per-checkout half,
  and `files` already carries both `component_id` and `working_copy_id`.

  Without that distinction, `CodeMySpecLocalWeb.EpicsLive` — deleted from the
  spec tree on 2026-08-10 by `ad775a1`, "Move the EpicsLive specs to where the
  code actually is" — stayed alive because three checkouts had not pulled. Their
  stale spec files kept re-projecting the component, `synced_at` stayed current,
  and every agent's ArchitectureDesign prompt reported an orphan context. The
  checkouts where the file was correctly gone were the ones asked to fix it,
  with four suggested resolutions that all act on a file they do not have.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Requirements.ArchitectureChecker
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "a context whose only spec lives in another checkout is not this one's orphan" do
    scope = full_scope_fixture()

    {:ok, mine} = WorkingCopies.issue(scope, nil, label: "mine")
    {:ok, theirs} = WorkingCopies.issue(scope, nil, label: "theirs")

    component = component_fixture(scope, %{module_name: "MyApp.Stale", type: "context"})

    # The spec exists only in the other checkout — the shape a stale worktree
    # leaves after a deletion it has not pulled.
    {1, _} =
      Files.upsert_files(%{scope | active_working_copy_id: theirs.id}, [
        %{
          path: ".code_my_spec/spec/my_app/stale.spec.md",
          role: :spec,
          component_id: component.id,
          mtime: DateTime.utc_now(),
          size: 1,
          fingerprint: "abc"
        }
      ])

    theirs_scope = %{scope | active_working_copy_id: theirs.id}
    mine_scope = %{scope | active_working_copy_id: mine.id}

    assert component.module_name in Enum.map(
             ArchitectureChecker.orphans(theirs_scope),
             & &1.module_name
           ),
           "the checkout that has the file owns the orphan and can resolve it"

    refute component.module_name in Enum.map(
             ArchitectureChecker.orphans(mine_scope),
             & &1.module_name
           ),
           "a checkout with no file for it cannot resolve it and must not be told to"
  end

  # NOT tested here, deliberately, and the reason is worth writing down.
  #
  # `ComponentSync.query_files/2` is project-wide on purpose — scoping it to a
  # harness would make `cleanup_removed/3` delete every component whose spec
  # lives only in another checkout, so three working copies syncing in turn
  # would take turns deleting each other's architecture. The comment on that
  # function says so.
  #
  # I wrote a test for it and deleted it, because it passed against a
  # deliberately-sabotaged `query_files` that *was* harness-scoped. With no
  # readable spec files the sync returns early on `merged == []` and
  # `cleanup_removed/3` never runs at all, so the component survived for a
  # reason that had nothing to do with the property. A test that cannot fail is
  # worse than no test: it reads as protection.
  #
  # Testing it honestly needs a real environment with spec files on disk, the
  # way `test/integration/stop_hook_sync_test.exs` sets one up. Worth doing when
  # somebody touches that query; not worth faking now.
end
