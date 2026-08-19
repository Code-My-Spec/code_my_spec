defmodule CodeMySpec.Files.UnchangedManifestTest do
  @moduledoc """
  A manifest that says nothing new writes nothing and projects nothing.

  Every join re-sent the whole tree and every row was re-upserted — 4,157 of
  them on a rejoin where nothing on disk had moved — followed by a full
  component projection (`925 components synced in 9000-9900ms`). Under a rejoin
  loop that is what exhausted the connection pool: `query_canceled ... while
  inserting index tuple in relation "files"`, and the next socket's upgrade
  dying in the queue behind it (`1aed7edf`, `600fbb3a`).

  The diff was already being computed and used only to decide what to re-embed.

  The dangerous half of this change is the definition of "unchanged", which is
  why it has more tests than the saving does: ownership is re-resolved
  server-side on every manifest, so a file can need writing with its content and
  fingerprint untouched.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)

    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    {:ok, scope: full_scope_fixture()}
  end

  defp observation(path, overrides \\ %{}) do
    Map.merge(
      %{
        path: path,
        role: :implementation,
        mtime: ~U[2026-07-28 10:00:00.000000Z],
        size: 120,
        fingerprint: "fp-#{path}",
        valid: true,
        validation_errors: %{}
      },
      overrides
    )
  end

  test "re-sending an identical manifest writes nothing", %{scope: scope} do
    manifest = [observation("lib/a.ex"), observation("lib/b.ex")]

    first = FileSync.reconcile_and_project(scope, manifest)
    assert first.upserted == 2

    second = FileSync.reconcile_and_project(scope, manifest)

    assert second.upserted == 0, """
    The second reconcile rewrote rows that already said exactly this.

    That is the join storm: a rejoin re-sends the whole tree, and re-upserting
    all of it holds a pooled connection through the index maintenance for every
    row — until the pool is gone and the next socket upgrade dies queued behind
    it.
    """

    assert second.changed == 0
  end

  test "and does not re-project the components", %{scope: scope} do
    manifest = [observation("lib/a.ex")]

    FileSync.reconcile_and_project(scope, manifest)
    second = FileSync.reconcile_and_project(scope, manifest)

    assert second.components == :unchanged, """
    The component projection ran for a manifest that changed no file.

    This is the expensive half — 9-10s against ~1s of upserts — and components
    are derived from File rows alone, so a reconcile that wrote and deleted
    nothing cannot have moved one.
    """
  end

  test "a changed fingerprint is still written", %{scope: scope} do
    FileSync.reconcile_and_project(scope, [observation("lib/a.ex")])

    edited = observation("lib/a.ex", %{fingerprint: "fp-edited"})
    result = FileSync.reconcile_and_project(scope, [edited])

    assert result.upserted == 1
    assert result.components != :unchanged, "a changed file can change a component"
  end

  # The regression this change could plausibly have caused, and the reason
  # `changed_entries/2` compares every replaceable column rather than the
  # fingerprint it used to.
  #
  # Ownership is resolved server-side on every manifest, against a read model
  # built in that request. A spex file whose story is created *after* the
  # harness joined gets a `story_id` with its bytes untouched — same content,
  # same fingerprint, different row. Judged on fingerprint alone it is
  # unchanged, so it would never be written, and `bdd_specs_exist` would stay
  # dark on a story whose spec file is sitting right there. That is the Drill 12
  # failure, read as a dead file watcher four separate times.
  test "an owner resolved since the last manifest is written, though the bytes did not move",
       %{scope: scope} do
    # `:declared_module` is scratch that `resolve_owners/2` reads and then
    # deletes — it never reaches a column. It is what makes the *same* manifest
    # resolve differently once the component exists, which is the whole scenario.
    manifest = [observation("lib/a.ex", %{declared_module: "Demo.A"})]

    FileSync.reconcile_and_project(scope, manifest)

    [stored] = Files.list_files(scope)

    assert is_nil(stored.component_id),
           "precondition: nothing owns it yet, because the component does not exist"

    component =
      CodeMySpec.ComponentsFixtures.component_fixture(scope, %{
        module_name: "Demo.A",
        name: "A"
      })

    # Byte-identical manifest. Only the server's read model has moved.
    result = FileSync.reconcile_and_project(scope, manifest)

    assert result.upserted == 1, """
    A file whose owner was resolved since the last manifest was treated as
    unchanged because its bytes had not moved.

    Ownership is decided here, not on the harness — `resolve_owners/2` re-runs
    against a read model built in this request — so it changes without the file
    changing. A diff that only reads the fingerprint cannot see it, and the
    result is `bdd_specs_exist` staying dark on a story whose spec file is
    sitting right there on disk.
    """

    [reloaded] = Files.list_files(scope)
    assert reloaded.component_id == component.id
  end

  test "a deletion still projects, though no surviving row changed", %{scope: scope} do
    manifest = [observation("lib/a.ex"), observation("lib/b.ex")]
    FileSync.reconcile_and_project(scope, manifest)

    result = FileSync.reconcile_and_project(scope, [observation("lib/a.ex")])

    assert result.removed == 1

    assert result.components != :unchanged, """
    A file was deleted and the components were not re-projected.

    Nothing that survived changed, so a check keyed only on `changed_entries`
    would skip — and the component the deleted file belonged to would keep a
    file that is gone.
    """
  end

  test "the skip is visible in the log", %{scope: scope} do
    manifest = [observation("lib/a.ex")]
    FileSync.reconcile_and_project(scope, manifest)

    log = capture_log(fn -> FileSync.reconcile_and_project(scope, manifest) end)

    assert log =~ "reconciled 1 observations",
           "a reconcile that did nothing still has to say it ran, or a quiet log " <>
             "reads as a harness that stopped syncing"
  end

  # The oscillation that kept `changed_entries` permanently non-empty, and with
  # it stopped the component projection from ever skipping (`d698ab0e`).
  #
  # The two directions are not equally well-defined. `ComponentSync`'s backfill
  # goes module → path (`CodeMySpec.Git.CLI` → `.../git/cli_test.exs`), which is
  # exact. `Scanner.resolve_owners/2` goes path → module by camelizing, and
  # `cli` camelizes to `Cli`, not `CLI` — so it cannot resolve any component
  # whose name carries an acronym. It answered `nil`, wrote that over the
  # backfill, and the backfill put it back inside the same transaction. Every
  # scan, on every working copy. Exactly two files on this project:
  # `Git.CLI` and `Git.URLParser`.
  test "a backfilled owner survives a manifest that cannot resolve one", %{scope: scope} do
    component =
      CodeMySpec.ComponentsFixtures.component_fixture(scope, %{
        module_name: "Demo.CLI",
        name: "CLI"
      })

    # `demo/cli` camelizes to `Demo.Cli`, which is not `Demo.CLI` — so
    # `resolve_owners/2` finds nothing and answers nil, the production shape.
    manifest = [observation("test/demo/cli_test.exs", %{role: :test})]
    FileSync.reconcile_and_project(scope, manifest)

    # Stand in for the backfill, which claims by path and never steals.
    [row] = Files.list_files(scope)

    {:ok, _} =
      row
      |> Ecto.Changeset.change(component_id: component.id)
      |> CodeMySpec.Repo.update()

    result = FileSync.reconcile_and_project(scope, manifest)

    assert result.upserted == 0, """
    The manifest wrote `component_id: nil` over an owner it has no rule to
    resolve.

    `ComponentSync` puts it back in the same transaction, so the end state was
    always correct and the write was always wasted — but the row then disagrees
    with the next manifest forever, which is what kept the projection skip from
    firing.
    """

    [reloaded] = Files.list_files(scope)

    assert reloaded.component_id == component.id,
           "and the owner has to still be there — preserving it is the point"
  end

  test "a story that resolve_owners drops is still cleared", %{scope: scope} do
    # The mirror of the clause above, asserted because the fix is deliberately
    # asymmetric: nothing else writes `story_id`, so a nil there really is this
    # function's answer and must be honoured.
    manifest = [observation("lib/b.ex")]
    FileSync.reconcile_and_project(scope, manifest)

    [row] = Files.list_files(scope)
    assert is_nil(row.story_id)
  end
end
