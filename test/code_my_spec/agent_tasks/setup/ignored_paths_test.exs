defmodule CodeMySpec.AgentTasks.Setup.IgnoredPathsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.Setup.IgnoredPaths
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync

  defp setup_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir), cwd: tmp_dir}
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule App, do: [app: :my_app]\n")
    %{scope: scope, tmp_dir: tmp_dir}
  end

  defp write_config_yml(tmp_dir, body) do
    cms_dir = Path.join(tmp_dir, ".code_my_spec")
    File.mkdir_p!(cms_dir)
    File.write!(Path.join(cms_dir, "config.yml"), body)
  end

  describe "evaluate/2" do
    setup :setup_scope

    test "returns invalid when config.yml is missing", %{scope: scope} do
      {:ok, _} = FileSync.sync(scope)
      assert {:ok, :invalid, feedback} = IgnoredPaths.evaluate(scope, %{})
      assert feedback =~ "not found"
    end

    test "returns invalid when config.yml has no ignored_paths list", %{scope: scope, tmp_dir: tmp_dir} do
      write_config_yml(tmp_dir, "name: my_app\n")
      {:ok, _} = FileSync.sync(scope)

      assert {:ok, :invalid, feedback} = IgnoredPaths.evaluate(scope, %{})
      assert feedback =~ "no `ignored_paths`"
    end

    test "returns valid when ignored_paths has entries", %{scope: scope, tmp_dir: tmp_dir} do
      write_config_yml(tmp_dir, """
      ignored_paths:
        - lib/my_app/repo.ex
        - lib/my_app_web/endpoint.ex
      """)

      {:ok, _} = FileSync.sync(scope)

      assert {:ok, :valid} = IgnoredPaths.evaluate(scope, %{})
    end
  end
end
