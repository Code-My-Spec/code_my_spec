defmodule CodeMySpec.ProblemsFixtures do
  @moduledoc """
  Test data for `CodeMySpec.Problems`.
  """

  alias CodeMySpec.Problems.Problem
  alias CodeMySpec.Repo

  @doc """
  Generate a valid problem attributes map.
  """
  def valid_problem_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      severity: :error,
      source_type: :static_analysis,
      source: "credo",
      file_path: "lib/my_app/example.ex",
      line: 42,
      message: "Modules should have a @moduledoc tag",
      category: "readability",
      rule: "Credo.Check.Readability.ModuleDoc",
      metadata: %{}
    })
  end

  @doc """
  Generate a problem fixture.
  Requires a scope with an active project.
  """
  def problem_fixture(scope, attrs \\ %{}) do
    attrs =
      attrs
      |> valid_problem_attrs()
      |> Map.put(:project_id, scope.active_project_id)
      # Problems belong to the working copy whose analyzer found them, the same
      # as the files they cite. Without this a fixture's problems are owned by
      # nobody and survive the reconcile that should have replaced them.
      |> Map.put(:working_copy_id, scope.active_working_copy_id)

    {:ok, problem} =
      %Problem{}
      |> Problem.changeset(attrs)
      |> Repo.insert()

    problem
  end

  @doc """
  Generate multiple problem fixtures.
  """
  def problem_list_fixture(scope, count, attrs \\ %{}) do
    Enum.map(1..count, fn i ->
      problem_fixture(scope, Map.merge(attrs, %{line: i}))
    end)
  end
end
