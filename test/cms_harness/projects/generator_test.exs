defmodule CmsHarness.Projects.GeneratorTest do
  @moduledoc """
  `Generator.run/2`'s own sequencing and skip logic, against a real temp
  directory but a scripted (never-shells-out) runner — see
  `CodeMySpecTest.ScriptedGeneratorRunner`'s own moduledoc for why a real
  `mix cms.new` is not something this suite can depend on.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Projects.Generator
  alias CodeMySpecTest.ScriptedGeneratorRunner, as: Runner

  setup do
    CmsHarnessTest.Projects.ensure_harness_supervisor_started()
    root = CodeMySpec.TempFile.dir("generator_test")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp pending(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        name: "Widget Tracker",
        app_name: "widget_tracker",
        deploy_key: "dk_test_#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  # Simulates every step this pipeline can take by matching on the command
  # `Generator` actually issues, so a change to the sequence itself would show
  # up here as an unmatched command rather than a silently-passing test.
  defp happy_script(dir) do
    fn
      _cwd, "mix", ["cms.new", ^dir, "--app", _app, "--no-install"] ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "mix.exs"), "# generated\n")
        {:ok, ""}

      _cwd, "mix", ["deps.get"] ->
        {:ok, ""}

      _cwd, "mix", ["ecto.create"] ->
        {:ok, ""}

      _cwd, "mix", ["ecto.migrate"] ->
        {:ok, ""}

      cwd, "mix", ["harness.onboard", "--deploy-key", _key, "--server-url", _url] ->
        :ok = HarnessConfig.write(cwd, %{working_copy_id: Ecto.UUID.generate()})
        {:ok, ""}
    end
  end

  test "generates, onboards, links and starts serving a project with nothing on disk yet", %{
    root: root
  } do
    project = pending()
    dir = Path.join(root, project.app_name)
    Runner.script(happy_script(dir))

    assert {:ok, ^dir} = Generator.run(project, projects_root: root)
    assert File.exists?(Path.join(dir, "mix.exs"))

    assert {:ok, %{working_copy_id: id, project_id: project_id}} =
             HarnessConfig.read_file(dir)

    assert is_binary(id)
    assert project_id == project.id
  end

  test "an already-generated, already-onboarded, already-linked project runs only deps and db",
       %{root: root} do
    project = pending()
    dir = Path.join(root, project.app_name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "# already generated\n")

    working_copy_id = Ecto.UUID.generate()

    :ok =
      HarnessConfig.write(dir, %{working_copy_id: working_copy_id, project_id: project.id})

    # cms.new and harness.onboard would refuse a non-empty directory / mint a
    # second working copy — reaching either here is the bug this guards.
    Runner.script(fn
      _cwd, "mix", ["deps.get"] -> {:ok, ""}
      _cwd, "mix", ["ecto.create"] -> {:ok, ""}
      _cwd, "mix", ["ecto.migrate"] -> {:ok, ""}
      _cwd, "mix", other -> flunk("should not have run mix #{Enum.join(other, " ")} again")
    end)

    assert {:ok, ^dir} = Generator.run(project, projects_root: root)

    assert {:ok, %{working_copy_id: ^working_copy_id, project_id: project_id}} =
             HarnessConfig.read_file(dir)

    assert project_id == project.id
  end

  test "generated and onboarded but not yet linked patches project_id without re-onboarding",
       %{root: root} do
    project = pending()
    dir = Path.join(root, project.app_name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "# already generated\n")

    working_copy_id = Ecto.UUID.generate()
    # Onboarded (has a working_copy_id) but not yet linked to a project — the
    # exact state a crash between `onboard/2` and `ensure_linked/3` leaves.
    :ok = HarnessConfig.write(dir, %{working_copy_id: working_copy_id})

    Runner.script(fn
      _cwd, "mix", ["deps.get"] -> {:ok, ""}
      _cwd, "mix", ["ecto.create"] -> {:ok, ""}
      _cwd, "mix", ["ecto.migrate"] -> {:ok, ""}
      _cwd, "mix", other -> flunk("should not have run mix #{Enum.join(other, " ")} again")
    end)

    assert {:ok, ^dir} = Generator.run(project, projects_root: root)

    assert {:ok, %{working_copy_id: ^working_copy_id, project_id: project_id}} =
             HarnessConfig.read_file(dir)

    assert project_id == project.id
  end

  test "a failed database step stops the pipeline before onboarding", %{root: root} do
    project = pending()
    dir = Path.join(root, project.app_name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "# already generated\n")

    Runner.script(fn
      _cwd, "mix", ["deps.get"] ->
        {:ok, ""}

      _cwd, "mix", ["ecto.create"] ->
        {:error, "could not connect to postgres"}

      _cwd, "mix", other ->
        flunk("should not have run mix #{Enum.join(other, " ")} after ecto.create failed")
    end)

    assert {:error, {:database, _reason}} = Generator.run(project, projects_root: root)
    assert HarnessConfig.read_file(dir) == :none
  end

  test "a failed generation step never runs deps or onboard", %{root: root} do
    project = pending()
    dir = Path.join(root, project.app_name)

    Runner.script(fn
      _cwd, "mix", ["cms.new", ^dir, "--app", _app, "--no-install"] ->
        {:error, "cms.new: unknown task"}

      _cwd, "mix", other ->
        flunk("should not have run mix #{Enum.join(other, " ")} after cms.new failed")
    end)

    assert {:error, {:generate, _reason}} = Generator.run(project, projects_root: root)
    refute File.exists?(dir)
  end
end
