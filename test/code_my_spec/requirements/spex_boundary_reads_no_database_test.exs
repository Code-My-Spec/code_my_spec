defmodule CodeMySpec.Requirements.SpexBoundaryReadsNoDatabaseTest do
  @moduledoc """
  The spex boundary is answered from the checkout's files, handed in.

  A harness checks its own files and has no database. Handed the files the
  database holds for the checkout, `spex_boundary_ready` answers what the
  database path answers, the app name its `mix.exs` declared included.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.SpexBoundaryChecker
  alias CodeMySpecTest.WithoutDatabase

  test "the verdict from the checkout's files, with no database, is the verdict from the database" do
    scope = full_scope_fixture()

    for {path, role, errors} <- [
          {"mix.exs", :mix_exs, %{"data" => %{"app_name" => "example"}}},
          {".code_my_spec/credo_checks/framework/spex_denied_calls.ex", :config, nil},
          {"test/support/fixtures/example_spex_fixtures.ex", :test_support, nil}
        ] do
      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        working_copy_id: scope.active_working_copy_id,
        path: path,
        role: role,
        valid: true,
        validation_errors: errors
      })
    end

    from_database = SpexBoundaryChecker.complete?(scope, nil)
    {false, %{reason: reason}} = from_database
    refute reason =~ "Could not determine app name", "the premise did not hold: no app name"

    files =
      Repo.all(from(f in FileRecord, where: f.working_copy_id == ^scope.active_working_copy_id))

    assert WithoutDatabase.run(fn ->
             SpexBoundaryChecker.complete?(scope, nil, %{files_by_project: files})
           end) == {:ok, from_database}
  end
end
