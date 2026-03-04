defmodule CodeMySpec.GitTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.{UsersFixtures, IntegrationsFixtures}
  import Mox

  alias CodeMySpec.Git
  alias CodeMySpec.Users.Scope

  setup :verify_on_exit!

  # ============================================================================
  # Unit Tests (Mocked)
  # ============================================================================

  describe "clone/3 - delegation" do
    setup do
      # Use MockGit for delegation testing
      original = Application.get_env(:code_my_spec, :git_impl_module)
      Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.MockGit)

      on_exit(fn ->
        Application.put_env(:code_my_spec, :git_impl_module, original)
      end)

      :ok
    end

    test "delegates to implementation module" do
      scope = %Scope{user: user_fixture()}
      url = "https://github.com/test/repo.git"
      path = "/tmp/test"

      expect(CodeMySpec.MockGit, :clone, fn ^scope, ^url, ^path ->
        {:ok, path}
      end)

      assert {:ok, ^path} = Git.clone(scope, url, path)
    end

    test "propagates success from implementation" do
      scope = %Scope{user: user_fixture()}

      expect(CodeMySpec.MockGit, :clone, fn _scope, _url, path ->
        {:ok, path}
      end)

      assert {:ok, _path} = Git.clone(scope, "https://github.com/test/repo.git", "/tmp/test")
    end

    test "propagates errors from implementation" do
      scope = %Scope{user: user_fixture()}

      expect(CodeMySpec.MockGit, :clone, fn _scope, _url, _path ->
        {:error, :not_connected}
      end)

      assert {:error, :not_connected} =
               Git.clone(scope, "https://github.com/test/repo.git", "/tmp/test")
    end
  end

  describe "pull/2 - delegation" do
    setup do
      # Use MockGit for delegation testing
      original = Application.get_env(:code_my_spec, :git_impl_module)
      Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.MockGit)

      on_exit(fn ->
        Application.put_env(:code_my_spec, :git_impl_module, original)
      end)

      :ok
    end

    test "delegates to implementation module" do
      scope = %Scope{user: user_fixture()}
      path = "/tmp/test"

      expect(CodeMySpec.MockGit, :pull, fn ^scope, ^path ->
        :ok
      end)

      assert :ok = Git.pull(scope, path)
    end

    test "propagates errors from implementation" do
      scope = %Scope{user: user_fixture()}

      expect(CodeMySpec.MockGit, :pull, fn _scope, _path ->
        {:error, :not_connected}
      end)

      assert {:error, :not_connected} = Git.pull(scope, "/tmp/test")
    end
  end

  # ============================================================================
  # Integration Test (Real Git Operations)
  # ============================================================================

  describe "Git.CLI integration" do
    setup do
      # Use real Git.CLI for integration tests
      Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.Git.CLI)

      on_exit(fn ->
        Application.put_env(:code_my_spec, :git_impl_module, CodeMySpec.Support.TestAdapter)
      end)

      :ok
    end

    @tag :integration
    @tag timeout: 60_000
    test "successfully clones and pulls from real repository" do
      user = user_fixture()
      token = "ghp_test_token_#{:rand.uniform(100_000)}"
      _integration = github_integration_fixture(user, %{access_token: token})
      scope = %Scope{user: user}

      clone_path = Path.join(System.tmp_dir!(), "git_cli_test_#{:rand.uniform(999_999)}")

      # Test clone
      test_repo = "https://github.com/Code-My-Spec/test_phoenix_project.git"
      assert {:ok, ^clone_path} = Git.clone(scope, test_repo, clone_path)
      assert File.exists?(clone_path)
      assert File.exists?(Path.join(clone_path, "mix.exs"))

      # Test pull
      assert :ok = Git.pull(scope, clone_path)

      # Cleanup
      File.rm_rf!(clone_path)
    end
  end
end
