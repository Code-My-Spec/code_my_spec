defmodule CodeMySpec.AgentTasks.Setup.IgnoredPathsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import Ecto.Query

  alias CodeMySpec.AgentTasks.Setup.IgnoredPaths
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo

  defp setup_scope(_context) do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    scope = %{scope | environment: Environment.new(:local, tmp_dir), cwd: tmp_dir}
    File.write!(Path.join(tmp_dir, "mix.exs"), "app: :my_app\n")
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
      assert {:ok, :invalid, feedback} = IgnoredPaths.evaluate(scope, %{})
      assert feedback =~ "not found"
    end

    test "returns invalid when config.yml has no ignored_paths list", %{scope: scope, tmp_dir: tmp_dir} do
      write_config_yml(tmp_dir, "name: my_app\n")

      assert {:ok, :invalid, feedback} = IgnoredPaths.evaluate(scope, %{})
      assert feedback =~ "no `ignored_paths`"
    end

    test "returns valid when ignored_paths has entries", %{scope: scope, tmp_dir: tmp_dir} do
      write_config_yml(tmp_dir, """
      ignored_paths:
        - lib/my_app/repo.ex
        - lib/my_app_web/endpoint.ex
      """)

      assert {:ok, :valid} = IgnoredPaths.evaluate(scope, %{})
    end
  end

  describe "evaluate/2 sync side-effect" do
    setup :setup_scope

    test "runs sync on success: non-ignored lib files land in the Files table", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      # Seed: one ignored (repo) + one kept (accounts context).
      File.mkdir_p!(Path.join(tmp_dir, "lib/my_app"))

      File.write!(
        Path.join(tmp_dir, "lib/my_app/repo.ex"),
        "defmodule MyApp.Repo do\nend\n"
      )

      File.write!(
        Path.join(tmp_dir, "lib/my_app/accounts.ex"),
        "defmodule MyApp.Accounts do\nend\n"
      )

      write_config_yml(tmp_dir, """
      ignored_paths:
        - lib/my_app/repo.ex
      """)

      assert {:ok, :valid} = IgnoredPaths.evaluate(scope, %{})

      paths =
        FileRecord
        |> where([f], f.project_id == ^scope.active_project_id)
        |> select([f], f.path)
        |> Repo.all()

      assert "lib/my_app/accounts.ex" in paths
      refute "lib/my_app/repo.ex" in paths
    end

    test "does not crash when active_project_id is nil", %{tmp_dir: tmp_dir} do
      write_config_yml(tmp_dir, """
      ignored_paths:
        - lib/my_app/repo.ex
      """)

      scope = %CodeMySpec.Users.Scope{
        user: nil,
        active_account: nil,
        active_account_id: nil,
        active_project: nil,
        active_project_id: nil,
        environment: Environment.new(:local, tmp_dir)
      }

      assert {:ok, :valid} = IgnoredPaths.evaluate(scope, %{})
    end
  end
end
