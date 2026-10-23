defmodule CodeMySpecDesktop.ProjectSetupTest do
  use CodeMySpecTest.DataCase, async: false
  alias CodeMySpecDesktop.ProjectSetup
  alias CodeMySpec.{Projects, WorkingCopies}
  alias CmsHarness.{HarnessConfig, Setup}

  setup do
    root = Path.join(System.tmp_dir!(), "project-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Example.MixProject do\n use Mix.Project\nend"
    )

    previous = System.get_env("CMS_PROJECT_DIR")
    System.put_env("CMS_PROJECT_DIR", Path.join(root, "workspace"))

    on_exit(fn ->
      if previous,
        do: System.put_env("CMS_PROJECT_DIR", previous),
        else: System.delete_env("CMS_PROJECT_DIR")

      File.rm_rf!(root)
    end)

    %{scope: CodeMySpec.UsersFixtures.full_scope_fixture(), root: root}
  end

  test "registers the selected project and reuses its main checkout", %{scope: scope, root: root} do
    device = Ecto.UUID.generate()
    assert {:ok, first} = ProjectSetup.register_checkout(scope, root, device)
    assert first.project_id == scope.active_project_id
    assert WorkingCopies.main(scope).id == first.id
    assert {:ok, second} = ProjectSetup.register_checkout(scope, root, device)
    assert second.id == first.id
    assert {:ok, project} = Projects.Onboarding.fetch(scope)
    assert project.local_path == root
    assert {:ok, config} = HarnessConfig.read_file(root)
    assert config.project_id == project.id
  end

  test "refuses another project's checkout without overwriting its identity", %{
    scope: scope,
    root: root
  } do
    other = Ecto.UUID.generate()

    assert :ok =
             HarnessConfig.write(root, %{project_id: other, working_copy_id: Ecto.UUID.generate()})

    assert {:error, {:project_identity_conflict, ^other}} =
             ProjectSetup.register_checkout(scope, root, Ecto.UUID.generate())

    assert WorkingCopies.main(scope) == nil
    assert {:ok, %{project_id: ^other}} = HarnessConfig.read_file(root)
  end

  test "device checks are reused while checkout records stay isolated", %{scope: scope} do
    assert {:ok, machine} = Setup.new_run()
    machine = Map.put(machine, "steps", [%{"key" => "elixir", "state" => "done"}])
    assert {:ok, project} = Setup.use_machine_checks(scope.active_project_id, machine)
    assert project["steps"] == machine["steps"]
    refute project["results_path"] == machine["results_path"]

    assert {:ok, _} =
             Setup.record_job(scope.active_project_id, %{
               result: %{"ok" => false, "error" => "failure"}
             })

    assert {:ok, stored} = Setup.project_status(scope.active_project_id)
    assert stored["job"]["result"]["error"] == "failure"
    assert {:ok, unchanged} = Setup.status()
    refute Map.has_key?(unchanged, "job")
  end

  test "Main can discover the setup tool without a working copy" do
    assert {:ok, CodeMySpec.Projects.Tools.SetupLocalProject} =
             CodeMySpec.ToolLibrary.fetch("setup_local_project")

    assert CodeMySpec.Agents.RoleProfile.carries?(:main, "setup_local_project")
    refute CodeMySpec.Agents.RoleProfile.carries?(:product, "setup_local_project")
  end

  test "explicit check reruns machine checks and records the same results for the project", %{
    scope: scope,
    root: root
  } do
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    previous_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", previous_path) end)

    for {name, output} <- [
          {"psql", "psql 16\nvector|0.8"},
          {"mise", "erlang 28\nelixir 1.19"},
          {"erl", "28"},
          {"elixir", "Elixir 1.19"},
          {"mix", "mix cms.new"},
          {"vibium", "Vibium 1"},
          {"just", "just 1.40.0"}
        ] do
      file = Path.join(bin, name)
      File.write!(file, "#!/bin/sh\nprintf '%s\\n' '#{output}'\n")
      File.chmod!(file, 0o700)
    end

    System.put_env("PATH", bin)
    {:ok, old} = Setup.new_run()
    {:ok, project} = Projects.Onboarding.fetch(scope)

    assert {:ok, %{prerequisites_passed: true}} =
             ProjectSetup.execute(scope, project, "check", nil)

    assert {:ok, machine} = Setup.status()
    assert {:ok, recorded} = Setup.project_status(project.id)
    refute machine["run_id"] == old["run_id"]
    assert Setup.prerequisites_passed?(recorded)
    assert recorded["steps"] == machine["steps"]
    File.write!(Path.join(bin, "elixir"), "#!/bin/sh\nexit 1\n")
    assert {:error, :prerequisites_failed} = ProjectSetup.execute(scope, project, "check", nil)
    assert {:ok, failed} = Setup.project_status(project.id)
    refute Setup.prerequisites_passed?(failed)
  end
end
