defmodule CodeMySpec.ProjectSetupWizard.ScriptGeneratorTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{UsersFixtures, AccountsFixtures, ProjectsFixtures}

  alias CodeMySpec.ProjectSetupWizard.ScriptGenerator

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)

    {:ok, scope: scope, user: user, account: account}
  end

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp project_without_repos(scope) do
    project_fixture(scope, %{
      name: "Project Without Repos",
      code_repo: nil,
      docs_repo: nil
    })
  end

  defp project_with_both_repos(scope) do
    project_fixture(scope, %{
      name: "Fully Configured Project",
      code_repo: "https://github.com/owner/code-repo.git",
      docs_repo: "https://github.com/owner/docs-repo.git"
    })
  end

  # ============================================================================
  # describe "generate/1" - Happy Path & Edge Cases
  # ============================================================================

  describe "generate/1" do
    test "generates bash script with git submodule commands", %{scope: scope} do
      project = project_with_both_repos(scope)

      assert {:ok, script} = ScriptGenerator.generate(project)

      assert String.contains?(script, "#!/bin/bash")
      assert String.contains?(script, "git submodule add")
      assert String.contains?(script, project.docs_repo)
    end

    test "includes Phoenix project creation command", %{scope: scope} do
      project = project_with_both_repos(scope)

      assert {:ok, script} = ScriptGenerator.generate(project)

      assert String.contains?(script, "mix phx.new")
    end

    test "includes git submodule initialization", %{scope: scope} do
      project = project_with_both_repos(scope)

      assert {:ok, script} = ScriptGenerator.generate(project)

      assert String.contains?(script, "git submodule update --init --recursive")
    end

    test "validates git repository before running", %{scope: scope} do
      project = project_with_both_repos(scope)

      assert {:ok, script} = ScriptGenerator.generate(project)

      assert String.contains?(script, ".git")

      assert String.contains?(script, "Not in a git repository") or
               String.contains?(script, "git repository")
    end

    test "handles missing repository URLs gracefully", %{scope: scope} do
      project = project_without_repos(scope)

      assert {:ok, script} = ScriptGenerator.generate(project)

      # Script should still be generated with comments or placeholders
      assert String.contains?(script, "#!/bin/bash")
      # Should not contain git submodule commands for missing repos
      refute String.contains?(script, "git submodule add https://")
    end

    test "script is idempotent and safe to re-run", %{scope: scope} do
      project = project_with_both_repos(scope)

      assert {:ok, script} = ScriptGenerator.generate(project)

      # Script should include checks to avoid errors on re-run
      # For example: checking if submodule/project already exists
      assert String.contains?(script, "if [ ! -d")
      assert String.contains?(script, "already exists")
    end
  end
end
