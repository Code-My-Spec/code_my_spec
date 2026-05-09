defmodule CodeMySpec.FilesTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "upsert_files/2 chunking" do
    test "inserts more rows than SQLite's 32766 parameter cap allows in a single insert" do
      # SQLite's compile-time SQLITE_MAX_VARIABLE_NUMBER is 32766.
      # With 13 columns per File row, that's 2520 max rows per
      # insert_all call. We feed 3000 — well past the single-call
      # ceiling — and expect chunking to split into batches.
      scope = full_scope_fixture()

      entries =
        for i <- 1..3000 do
          %{
            path: "lib/chunked/file_#{i}.ex",
            role: :implementation,
            mtime: ~U[2026-05-09 00:00:00.000000Z],
            size: 100,
            fingerprint: "fp_#{i}",
            valid: true,
            validation_errors: nil,
            component_id: nil,
            story_id: nil
          }
        end

      {count, files} = Files.upsert_files(scope, entries)

      assert count == 3000
      assert length(files) == 3000
    end

    test "an empty list is a no-op (zero rows, empty list)" do
      scope = full_scope_fixture()

      assert {0, []} = Files.upsert_files(scope, [])
    end
  end
end
