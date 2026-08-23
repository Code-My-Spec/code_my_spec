defmodule CodeMySpec.AgentTasks.Setup.LightHarnessTest do
  @moduledoc """
  The setup steps on a scope with no environment.

  That is not an edge case — it is the light harness's normal shape. The server
  holds no working copy, so `scope.environment` is nil and every step that
  reaches for a disk finds nothing there.

  Both behaviours below were found by an agent, in a container, mid-drill,
  because nothing in the suite ran a setup step without a disk. The unit tests
  each build an environment; the integration tests use a tmp dir. A nil
  environment was reachable only in production.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.Setup
  alias CodeMySpec.AgentTasks.Setup.{Context, Helpers}
  alias CodeMySpec.Files.File, as: FileRecord

  setup do
    scope = full_scope_fixture()
    # Explicit, because it is the property under test: no working copy here.
    %{scope: %{scope | environment: nil}}
  end

  defp sync_file(scope, path, role) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: role,
      valid: true,
      validation_errors: %{}
    })
  end

  defp sync_mix_exs(scope, app_name) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: "mix.exs",
      role: :mix_exs,
      valid: true,
      validation_errors: %{"data" => %{"app_name" => app_name}}
    })
  end

  describe "directories, with no disk to stat" do
    test "a directory holding a synced file is present", %{scope: scope} do
      sync_file(scope, ".code_my_spec/rules/design.md", :rule)

      ctx = Context.load(scope)

      assert Context.dir_status(ctx, ".code_my_spec/rules") == :present
    end

    test "a directory with nothing under it is unobservable, not absent", %{scope: scope} do
      ctx = Context.load(scope)

      assert Context.dir_status(ctx, ".code_my_spec/rules") == :unobservable,
             "`:absent` here is a claim the server cannot support, and it is not " <>
               "a claim the agent can refute: directories are not synced, so no " <>
               "mkdir changes the answer"
    end

    test "a sibling with a shared prefix does not count", %{scope: scope} do
      sync_file(scope, ".code_my_spec/spec/my_app_web/thing.md", :rule)

      ctx = Context.load(scope)

      assert Context.dir_status(ctx, ".code_my_spec/spec/my_app") == :unobservable
    end

    test "ProjectStructure does not report a directory it cannot see", %{scope: scope} do
      sync_mix_exs(scope, "my_app")

      assert {:ok, :valid} = Setup.ProjectStructure.evaluate(scope, %{}),
             "this is the step an agent worked at and could not finish: it created " <>
               "every directory, they were on disk, and the check still called them " <>
               "missing on every re-evaluation"
    end
  end

  describe "tools that need a working copy" do
    test "no working directory resolves to no environment, not to the server's own" do
      frame = %{assigns: %{}}

      assert CodeMySpec.McpServers.Validators.mcp_environment(frame) == nil,
             "this returned `Environment.new(:local, File.cwd!())`, so every " <>
               "filesystem tool on the server-hosted mount operated on the " <>
               "server's own checkout — and reported success for it"
    end

    test "install refuses rather than writing somewhere else" do
      alias CodeMySpec.McpServers.Bootstrap.Tools

      for tool <- [
            Tools.InstallAgentsMd,
            Tools.InstallClaudeMd,
            Tools.InstallRules,
            Tools.InstallCredoChecks
          ] do
        assert tool.install(nil) == {:error, :no_working_copy}
      end
    end
  end

  describe "prompts that have to name a module" do
    test "the app name comes from the synced mix.exs", %{scope: scope} do
      sync_mix_exs(scope, "my_app")

      assert Helpers.app_name(scope) == "my_app"
    end

    test "falls back rather than raising when nothing is synced", %{scope: scope} do
      assert Helpers.app_name(scope) == "your_app"
    end

    for step <- [
          Setup.ApplicationInWeb,
          Setup.SpexCase,
          Setup.TestSupportNamespace,
          Setup.TestBoundaries,
          Setup.ProjectStructure
        ] do
      test "#{inspect(step)}.command/2 builds a prompt naming the real app", %{scope: scope} do
        sync_mix_exs(scope, "my_app")

        # Raised before: `Environments.read_file(nil, "mix.exs")` had no matching
        # clause, so `start_task` returned a FunctionClauseError for these steps
        # and the agent never received a prompt at all.
        assert {:ok, prompt} = unquote(step).command(scope, %{})

        assert prompt =~ "my_app" or prompt =~ "MyApp",
               "a prompt that says `your_app` sends the agent to write the wrong " <>
                 "module names, which is quieter than crashing and worse"
      end
    end
  end
end
