defmodule CodeMySpec.Provisioning.RestoreDatabaseDumpTest do
  @moduledoc """
  Issue 497e0750: restoring an uploaded pg_dump into a cutover's tenant
  database, safely. `Steps.restore_database_dump/4` is the thin wiring
  layer — the actual refusal, pre-restore dump and row-count checks are
  `Database.restore_dump/4`'s own, covered in `DatabaseTest`.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Steps

  setup do
    %{scope: provisioning_scope_fixture()}
  end

  # Both databases answer the same row-count query; the target is reported
  # empty throughout, which is the simplest path through `restore_dump/4`.
  defp empty_run do
    fn [command] -> empty_response(String.contains?(command, "json_object_agg")) end
  end

  defp empty_response(true), do: {"{}", 0}
  defp empty_response(false), do: {"", 0}

  test "an opts[:run] bypasses SSH entirely, the same way :import's does", %{scope: scope} do
    {:ok, _} = Environments.put(scope, "uat", %{})

    assert {:ok, %{rows: %{}}} =
             Steps.restore_database_dump(scope, "uat", "/uploads/fly-prod.dump", run: empty_run())
  end

  test "with no server access configured, it refuses rather than guessing a box", %{
    scope: scope
  } do
    {:ok, _} = Environments.put(scope, "uat", %{})

    assert {:error, message} =
             Steps.restore_database_dump(scope, "uat", "/uploads/fly-prod.dump", [])

    assert message =~ "could not reach uat's server"
  end
end
