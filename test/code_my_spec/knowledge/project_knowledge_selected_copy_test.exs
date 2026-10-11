defmodule CodeMySpec.Knowledge.ProjectKnowledgeSelectedCopyTest do
  use ExUnit.Case, async: false

  import CodeMySpec.UsersFixtures,
    only: [fixture_environment: 1, full_scope_fixture: 0, put_fixture_environment: 2]

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Knowledge
  alias CodeMySpec.Repo
  alias CodeMySpec.TempFile
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Repo)

    scope = full_scope_fixture()
    stale_environment = fixture_environment(scope)
    selected_root = TempFile.owned_dir("knowledge_selected_copy")
    selected_environment = Environment.new(:local, selected_root)
    scope = put_fixture_environment(scope, selected_environment)

    :ok =
      Environments.write_file(
        selected_environment,
        ".code_my_spec/knowledge/README.md",
        "# Selected checkout knowledge\n"
      )

    %{scope: scope, stale_environment: stale_environment}
  end

  test "project knowledge is read from the selected working copy", %{
    scope: scope,
    stale_environment: stale_environment
  } do
    assert {:ok, { :file, "# Selected checkout knowledge\n" }} =
             Knowledge.browse(scope, :project_knowledge, ["README.md"])

    assert {:error, :not_found} =
             Knowledge.browse(scope, :project_knowledge, ["missing.md"])

    refute stale_environment.cwd == scope.cwd
  end
end
