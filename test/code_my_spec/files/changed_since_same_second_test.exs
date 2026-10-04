defmodule CodeMySpec.Files.ChangedSinceSameSecondTest do
  @moduledoc """
  da2af26. A file's mtime comes from `stat`, which resolves whole seconds; a
  task's start keeps microseconds. An edit in the same second the task started
  must still count as changed since it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.Repo

  defp file!(scope, path, mtime) do
    Repo.insert!(%Files.File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: :implementation,
      fingerprint: "sha-#{System.unique_integer([:positive])}",
      size: 10,
      valid: true,
      mtime: mtime
    })
  end

  test "an edit in the same second the task started is changed since it" do
    scope = full_scope_fixture()
    second = ~U[2026-10-04 01:00:00.000000Z]
    file!(scope, "lib/edited_same_second.ex", second)
    file!(scope, "lib/edited_before.ex", DateTime.add(second, -1, :second))

    started = DateTime.add(second, 500_000, :microsecond)

    assert ["lib/edited_same_second.ex"] =
             scope |> Files.changed_since(started) |> Enum.map(& &1.path)
  end
end
