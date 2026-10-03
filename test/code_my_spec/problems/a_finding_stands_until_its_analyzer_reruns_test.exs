defmodule CodeMySpec.Problems.AFindingStandsUntilItsAnalyzerRerunsTest do
  @moduledoc """
  A finding is retired by the next run of its analyzer, never by its file
  changing (28d72f8a). Editing the file leaves the finding standing — an agent
  cannot clear the gate by touching it (story 988, criterion 8201) — and the
  rerun replaces the source's whole set, so whatever it does not re-report is
  gone.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Problems
  alias CodeMySpec.Repo

  @path "lib/thing.ex"

  defp file_at(scope, fingerprint) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: @path,
      role: :implementation,
      fingerprint: fingerprint,
      mtime: DateTime.utc_now(),
      size: 100,
      valid: true
    })
  end

  defp finding do
    %{
      file_path: @path,
      line: 86,
      severity: :warning,
      source_type: :static_analysis,
      source: "credo",
      category: "readability",
      message: "Imperative `if` is not allowed"
    }
  end

  defp paths(scope), do: scope |> Problems.list_project_problems([]) |> Enum.map(& &1.file_path)

  setup do
    scope = full_scope_fixture()
    tracked = file_at(scope, "sha-old")
    {:ok, _} = Problems.reconcile_problems_for_source(scope, "credo", :all, [finding()])
    %{scope: scope, tracked: tracked}
  end

  test "an edit to the file does not retire the finding", %{scope: scope, tracked: tracked} do
    tracked |> Ecto.Changeset.change(fingerprint: "sha-new") |> Repo.update!()

    assert @path in paths(scope)
  end

  test "the analyzer's next run retires what it does not re-report", %{scope: scope} do
    {:ok, _} = Problems.reconcile_problems_for_source(scope, "credo", :all, [])

    refute @path in paths(scope)
  end
end
