defmodule CodeMySpec.Files.ComponentRenamesTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.{Components, Files, Stories}
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Files.{ComponentExtract, FileSync, Scanner}

  @tag :tmp_dir
  test "a module moved and renamed between scans retains its authored identity and links", %{
    tmp_dir: root
  } do
    scope = full_scope_fixture()
    component = component_fixture(scope, %{module_name: "MyApp.Before", provenance: :authored})
    story = story_fixture(scope, %{component_id: component.id})
    old_path = write_module(root, "before.ex", "MyApp.Before")
    scan(scope, root)
    assert [old_file] = Files.list_files(scope)
    assert old_file.component_id == component.id

    new_path = Path.join(root, "lib/after.ex")
    File.rename!(old_path, new_path)
    File.write!(new_path, String.replace(File.read!(new_path), "MyApp.Before", "MyApp.After"))
    scan(scope, root)

    assert [renamed] = Components.list_components(scope)
    assert renamed.id == component.id
    assert renamed.module_name == "MyApp.After"
    assert renamed.provenance == :authored
    assert renamed.description == component.description
    assert Stories.get_story(scope, story.id).component_id == component.id
    assert [new_file] = Files.list_files(scope)
    assert new_file.path == "lib/after.ex"
    assert new_file.component_id == component.id

    requirements =
      CodeMySpec.Requirements.RequirementCalculator.compute_component(scope, renamed)

    assert implementation = Enum.find(requirements, &(&1.name == "implementation_file"))
    assert implementation.satisfied
    scan(scope, root)
    assert [same] = Components.list_components(scope)
    assert same.id == component.id
  end

  @tag :tmp_dir
  test "a genuinely deleted authored implementation remains present as a missing component", %{
    tmp_dir: root
  } do
    scope = full_scope_fixture()
    component = component_fixture(scope, %{module_name: "MyApp.Deleted", provenance: :authored})
    path = write_module(root, "deleted.ex", "MyApp.Deleted")
    scan(scope, root)
    File.rm!(path)
    scan(scope, root)

    assert retained = Components.get_component(scope, component.id)
    assert retained.module_name == "MyApp.Deleted"
    assert retained.provenance == :authored
    assert Files.list_files(scope) == []

    requirements =
      CodeMySpec.Requirements.RequirementCalculator.compute_component(scope, retained)

    assert implementation = Enum.find(requirements, &(&1.name == "implementation_file"))
    refute implementation.satisfied
  end

  @tag :tmp_dir
  test "identical bodies are ambiguous and do not transfer component identity", %{tmp_dir: root} do
    scope = full_scope_fixture()
    component = component_fixture(scope, %{module_name: "MyApp.Before", provenance: :authored})
    old_path = write_module(root, "before.ex", "MyApp.Before")
    write_module(root, "duplicate.ex", "MyApp.Duplicate")
    scan(scope, root)
    File.rm!(old_path)
    write_module(root, "after.ex", "MyApp.After")
    scan(scope, root)

    assert Components.get_component(scope, component.id).module_name == "MyApp.Before"
    assert Components.get_component_by_module_name(scope, "MyApp.After").id != component.id
  end

  @tag :tmp_dir
  test "a feature copy cannot rename the shared component ahead of main", %{tmp_dir: root} do
    scope = full_scope_fixture()

    Repo.get!(CodeMySpec.WorkingCopies.WorkingCopy, scope.active_working_copy_id)
    |> Ecto.Changeset.change(main: true)
    |> Repo.update!()

    component = component_fixture(scope, %{module_name: "MyApp.Before", provenance: :authored})
    old_path = write_module(root, "before.ex", "MyApp.Before")
    scan(scope, root)

    {:ok, team} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "rename-feature",
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    feature_scope = %{scope | active_working_copy_id: team.id}
    scan(feature_scope, root)
    File.rm!(old_path)
    write_module(root, "after.ex", "MyApp.After")
    scan(feature_scope, root)

    assert Components.get_component(scope, component.id).module_name == "MyApp.Before"
    assert Components.get_component_by_module_name(scope, "MyApp.After") == nil
  end

  test "empty and unparseable modules provide no rename fingerprint" do
    assert ComponentExtract.rename_fingerprint("defmodule Empty do end") == nil
    assert ComponentExtract.rename_fingerprint("defmodule Broken do") == nil
  end

  defp write_module(root, filename, name) do
    path = Path.join([root, "lib", filename])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule #{name} do\n  def answer, do: 42\nend\n")
    path
  end

  defp scan(scope, root) do
    {:ok, observations} =
      Scanner.observe(ExecutionContext.new(:local, root), Files.read_model(scope))

    FileSync.reconcile_and_project(scope, observations)
  end
end
