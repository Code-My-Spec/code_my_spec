defmodule CodeMySpec.Files.UpsertReturnsWhatChangedTest do
  @moduledoc """
  One statement synchronises the file table and says what moved.

  `upsert_files/2` updates a conflicting row only where a replaceable column
  differs, and `RETURNING` hands back exactly the rows it touched. That makes
  the write and the answer to "what changed" the same operation, and it makes
  hydrating a cold table and reconciling a warm one the same operation too —
  a cold table conflicts with nothing, so everything inserts and everything
  comes back.

  It replaced a hand-written diff: load the whole file table, compare eight
  fields per observation in Elixir, upsert the survivors. The comparison was the
  dangerous half and had been wrong twice — once judging on fingerprint alone,
  which hid a spex file that gained a `story_id` without its bytes moving, and
  once producing a false positive that took two rounds of guessing to find. So
  the definition of "changed" is what this file tests, field by field, rather
  than the saving.

  `unchanged_manifest_test.exs` covers the same ground through `reconcile/2`,
  where ownership is re-resolved first. This is the statement on its own.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    {:ok, scope: full_scope_fixture()}
  end

  defp entry(path, overrides \\ %{}) do
    Map.merge(
      %{
        path: path,
        role: :implementation,
        mtime: ~U[2026-09-16 10:00:00.000000Z],
        size: 120,
        fingerprint: "fp-#{path}",
        valid: true,
        validation_errors: %{}
      },
      overrides
    )
  end

  defp paths_returned({_count, rows}), do: rows |> Enum.map(& &1.path) |> Enum.sort()

  describe "hydrating and reconciling are one operation" do
    test "a cold table returns every row", %{scope: scope} do
      manifest = [entry("lib/a.ex"), entry("lib/b.ex"), entry("lib/c.ex")]

      {count, rows} = Files.upsert_files(scope, manifest)

      assert count == 3
      assert paths_returned({count, rows}) == ~w(lib/a.ex lib/b.ex lib/c.ex)

      assert length(rows) == count,
             """
             The count and the returned rows disagree.

             They are the same fact and the caller uses both: the count is
             logged and the rows are the event list. A statement where they can
             differ has one of them derived from something other than what it
             actually wrote.
             """
    end

    test "re-sending the identical manifest returns nothing", %{scope: scope} do
      manifest = [entry("lib/a.ex"), entry("lib/b.ex")]

      {2, _} = Files.upsert_files(scope, manifest)
      {count, rows} = Files.upsert_files(scope, manifest)

      assert count == 0
      assert rows == []
    end

    test "a manifest that adds one file returns only that file", %{scope: scope} do
      {2, _} = Files.upsert_files(scope, [entry("lib/a.ex"), entry("lib/b.ex")])

      result = Files.upsert_files(scope, [entry("lib/a.ex"), entry("lib/b.ex"), entry("lib/c.ex")])

      assert paths_returned(result) == ["lib/c.ex"]
    end
  end

  describe "what counts as changed" do
    setup %{scope: scope} do
      {1, _} = Files.upsert_files(scope, [entry("lib/a.ex")])
      :ok
    end

    for {field, value, why} <- [
          {:fingerprint, "fp-moved", "the content moved"},
          {:mtime, ~U[2026-09-16 11:00:00.000000Z], "the file was touched"},
          {:size, 999, "the file grew"},
          {:role, :test, "the file was reclassified"},
          {:valid, false, "it stopped parsing"},
          {:validation_errors, %{"reason" => "missing sections"}, "the reason changed"}
        ] do
      test "#{field} moving is a change — #{why}", %{scope: scope} do
        result = Files.upsert_files(scope, [entry("lib/a.ex", %{unquote(field) => unquote(Macro.escape(value))})])

        assert paths_returned(result) == ["lib/a.ex"],
               """
               `#{unquote(field)}` moved and the row was not written.

               Every column the upsert can overwrite has to be compared, or a
               file whose bytes are identical stops being re-examined. That is
               the fingerprint-only comparison this replaced: a spex file that
               gained an owner without its content moving was judged unchanged,
               and `bdd_specs_exist` stayed dark on nine stories that had spec
               files on disk.
               """
      end
    end

    test "mtime alone is enough, though nothing about the content moved", %{scope: scope} do
      result = Files.upsert_files(scope, [entry("lib/a.ex", %{mtime: ~U[2026-09-16 12:00:00.000000Z]})])

      assert paths_returned(result) == ["lib/a.ex"],
             """
             A touched file reported itself unchanged.

             `sync_changed/2` reads stored mtime to decide which files to open
             at all, so a stored mtime that never advances makes that file
             re-read on every scan forever.
             """
    end

    test "writing the same change twice only reports it once", %{scope: scope} do
      changed = [entry("lib/a.ex", %{fingerprint: "fp-moved"})]

      assert paths_returned(Files.upsert_files(scope, changed)) == ["lib/a.ex"]
      assert paths_returned(Files.upsert_files(scope, changed)) == []
    end

    test "one changed file among many returns one row", %{scope: scope} do
      steady = for n <- 1..20, do: entry("lib/f#{n}.ex")
      {20, _} = Files.upsert_files(scope, steady)

      moved =
        List.replace_at(steady, 7, entry("lib/f8.ex", %{fingerprint: "fp-moved"}))

      assert paths_returned(Files.upsert_files(scope, moved)) == ["lib/f8.ex"],
             """
             A manifest of twenty files with one real change did not return
             exactly that one.

             This is the whole claim: the cost of a sync is proportional to what
             moved, and the caller learns what moved from the same statement
             that wrote it.
             """
    end
  end

  describe "updated_at" do
    test "does not move on a row the statement skipped", %{scope: scope} do
      {1, [written]} = Files.upsert_files(scope, [entry("lib/a.ex")])

      {0, []} = Files.upsert_files(scope, [entry("lib/a.ex")])

      [stored] = Files.list_files(scope)

      assert stored.updated_at == written.updated_at,
             """
             A row nothing changed still had its `updated_at` rewritten.

             `GraphFingerprint` refuses to hash timestamps for exactly this
             reason — a no-op sync that bumps every `updated_at` is a
             fingerprint that never settles.
             """
    end
  end

  describe "what was removed comes back too" do
    test "the delete returns the rows it deleted", %{scope: scope} do
      {2, _} = Files.upsert_files(scope, [entry("lib/a.ex"), entry("lib/b.ex")])

      {count, removed} = Files.delete_removed(scope, ["lib/a.ex"])

      assert count == 1
      assert Enum.map(removed, & &1.path) == ["lib/b.ex"]

      assert Enum.map(removed, & &1.role) == [:implementation],
             """
             The removed rows came back without their roles.

             Embedding cleanup keys on `{source, path}`, so a deletion that
             cannot say what role the file had leaves its embedding behind —
             and the alternative to returning them is reading the whole file
             table to find the few that are gone.
             """
    end

    test "deleting nothing returns nothing", %{scope: scope} do
      {2, _} = Files.upsert_files(scope, [entry("lib/a.ex"), entry("lib/b.ex")])

      assert {0, []} = Files.delete_removed(scope, ["lib/a.ex", "lib/b.ex"])
    end
  end
end
