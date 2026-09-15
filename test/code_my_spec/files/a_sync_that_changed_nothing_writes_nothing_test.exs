defmodule CodeMySpec.Files.ASyncThatChangedNothingWritesNothingTest do
  @moduledoc """
  Syncing a component whose content is identical must not touch its row.

  It used to touch every row, every run. `upsert_component/4` set
  `synced_at: DateTime.utc_now()` on every component, so the changeset always
  carried a change, so Ecto always wrote, so `updated_at` moved on all of them.

  That would be invisible bookkeeping if anything but bookkeeping read it.
  `Requirements.Freshness.component/2` hashes `row_key(component)`, which is
  `{id, updated_at}` — so one full sync moved every component's input
  fingerprint simultaneously, and the next graph read in every working copy
  found the whole thing stale and recomputed all of it. Per vantage.

  Measured on this project, in order:

      07:35:45  [Files.ComponentSync] 1102 components synced in 30627ms (1102 changed)
      07:36:09  full recompute — everything_stale ... mismatched=1124 ... ctx=1124c/81s
      08:30:58  full recompute — everything_stale ... mismatched=1124 ... ctx=1124c/33s

  1124 of 1124 components, on each checkout's first read afterwards.

  The "1102 changed" was the same defect wearing a different hat:
  `component_changed?/2` compares `updated_at` before the write against
  `updated_at` after it, so it reported whether the write had bumped the clock
  rather than whether anything differed. It always had, so the count was always
  everything, and it agreed with itself no matter what the files said.

  `synced_at` is safe to leave behind — checked rather than assumed.
  `cleanup_removed/3` and `cleanup_orphaned/3` both decide by module-name set
  difference, and no other module reads the column.
  """

  use CodeMySpecTest.DataCase, async: true

  import Ecto.Query

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Repo

  @module_name "CodeMySpec.Widgets"

  # Carries scanner-stored data, so the sync parses it from the row and never
  # reaches for a disk that is not there — the ordinary path in production,
  # where 1494 of 1519 specs arrive this way.
  defp spec_with_stored_data!(scope, attrs) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: "specs/widgets.md",
      role: :spec,
      fingerprint: "sha-#{System.unique_integer([:positive])}",
      size: 100,
      valid: true,
      validation_errors: %{"data" => attrs}
    })
  end

  setup do
    scope = full_scope_fixture()

    component_fixture(scope, %{name: "Widgets", module_name: @module_name})

    spec_with_stored_data!(scope, %{
      "module_name" => @module_name,
      "type" => "context",
      "description" => "Widgets, as they are",
      "dependencies" => []
    })

    # No environment, matching the light-harness server: nothing may depend on
    # reading a file here.
    %{scope: %{scope | environment: nil, cwd: nil}}
  end

  defp settled_component(scope) do
    {:ok, _} = ComponentSync.sync_from_files(scope)
    Components.list_components(scope) |> Enum.find(&(&1.module_name == @module_name))
  end

  test "a second sync over unchanged content leaves updated_at alone", %{scope: scope} do
    # The first sync is allowed to write — it is the one applying the spec's
    # type and description to a fixture that had neither.
    first = settled_component(scope)

    # Both stamps, and both are load-bearing. `updated_at` because it is
    # second-resolution, so a second sync inside the same second leaves it
    # identical whether it wrote or not. `synced_at` because it is the field
    # that makes the changeset non-empty: two syncs in one second compute the
    # same `synced_at`, Ecto sees no change and no-ops, and the defect cannot
    # appear at all. In production syncs are minutes apart, so it always
    # differs and always writes.
    #
    # Without both lines this test passed against the unfixed code, which is
    # the only reason the instrument was checked rather than trusted.
    Repo.update_all(
      from(c in CodeMySpec.Components.Component, where: c.id == ^first.id),
      set: [updated_at: ~U[2020-01-01 00:00:00.000000Z], synced_at: ~U[2020-01-01 00:00:00.000000Z]]
    )

    {:ok, result} = ComponentSync.sync_from_files(scope)

    again =
      Components.list_components(scope) |> Enum.find(&(&1.module_name == @module_name))

    assert again.updated_at == ~U[2020-01-01 00:00:00.000000Z], """
    The second sync rewrote a component nothing had changed, moving its
    `updated_at`. `Freshness.component/2` hashes `{id, updated_at}`, so that
    single write invalidates this component's fingerprint in every working
    copy, and a sync doing it to all of them at once costs a full graph
    recompute per vantage — measured at 1124 of 1124 components stale.
    """

    refute again.id in result.changed_component_ids, """
    A component nothing touched was reported as changed. `component_changed?/2`
    compares `updated_at` either side of the write, so if the write happens
    unconditionally the count is unconditionally everything — the measurement
    and the defect are the same fact, which is why "1102 changed" looked
    plausible for so long.
    """
  end

  test "a real content change is still written", %{scope: scope} do
    first = settled_component(scope)

    # Backdated rather than slept through. `updated_at` is second-resolution,
    # so two syncs in the same second leave it identical whether the second one
    # wrote or not — which made this assertion fail against a write that had
    # plainly happened, the description beside it having changed.
    Repo.update_all(
      from(c in CodeMySpec.Components.Component, where: c.id == ^first.id),
      set: [updated_at: ~U[2020-01-01 00:00:00.000000Z], synced_at: ~U[2020-01-01 00:00:00.000000Z]]
    )

    Repo.update_all(
      CodeMySpec.Files.File,
      set: [
        validation_errors: %{
          "data" => %{
            "module_name" => @module_name,
            "type" => "context",
            "description" => "Widgets, reconsidered",
            "dependencies" => []
          }
        }
      ]
    )

    {:ok, result} = ComponentSync.sync_from_files(scope)

    again =
      Components.list_components(scope) |> Enum.find(&(&1.module_name == @module_name))

    assert again.description == "Widgets, reconsidered",
           "skipping the write when content matches must not skip it when content differs"

    assert DateTime.compare(again.updated_at, ~U[2020-01-01 00:00:00.000000Z]) == :gt,
           "the backdated stamp must have moved forward, i.e. the row was written"

    assert again.id in result.changed_component_ids
  end
end
