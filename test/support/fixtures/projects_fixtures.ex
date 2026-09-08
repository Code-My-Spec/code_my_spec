defmodule CodeMySpec.ProjectsFixtures do
  @moduledoc """
  Test data for `CodeMySpec.Projects`.
  """

  @doc """
  Generate a project.
  """
  def project_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        code_repo: "some code_repo",
        module_name: "MyApp",
        docs_repo: "https://github.com/test/docs-repo.git",
        name: "some name",
        setup_error: "some setup_error",
        status: :created
      })

    {:ok, project} = CodeMySpec.Projects.create_project(scope, attrs)
    project
  end
end
