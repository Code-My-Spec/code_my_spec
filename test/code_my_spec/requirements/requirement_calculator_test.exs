defmodule CodeMySpec.Requirements.RequirementCalculatorTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Projects

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "compute_component/2 — file existence" do
    test "spec_file satisfied when spec exists" do
      {scope, tmp_dir, component} = setup_component("schema")

      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget.spec.md", spec_content())
      sync!(scope, tmp_dir)

      results = RequirementCalculator.compute_component(scope, component)
      spec_req = find_req(results, "spec_file")

      assert spec_req.satisfied
    end

    test "spec_file unsatisfied when no spec" do
      {scope, _tmp_dir, component} = setup_component("schema")

      # No files written — no sync needed, but run anyway to ensure clean state
      results = RequirementCalculator.compute_component(scope, component)
      spec_req = find_req(results, "spec_file")

      refute spec_req.satisfied
    end

    test "implementation_file satisfied when impl exists" do
      {scope, tmp_dir, component} = setup_component("schema")

      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget.spec.md", spec_content())
      write_file(tmp_dir, "lib/my_app/widget.ex", impl_content())
      sync!(scope, tmp_dir)

      results = RequirementCalculator.compute_component(scope, component)
      impl_req = find_req(results, "implementation_file")

      assert impl_req.satisfied
    end

    test "implementation_file unsatisfied when missing" do
      {scope, tmp_dir, component} = setup_component("schema")

      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget.spec.md", spec_content())
      sync!(scope, tmp_dir)

      results = RequirementCalculator.compute_component(scope, component)
      impl_req = find_req(results, "implementation_file")

      refute impl_req.satisfied
    end
  end

  describe "compute_component/2 — file validity" do
    test "spec_valid satisfied when file is marked valid" do
      {scope, tmp_dir, component} = setup_component("schema")

      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget.spec.md", spec_content())
      sync!(scope, tmp_dir)

      # Mark the spec as valid
      file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/widget.spec.md")
      {:ok, _} = Files.mark_validated(file, true)

      results = RequirementCalculator.compute_component(scope, reload(scope, component))
      valid_req = find_req(results, "spec_valid")

      assert valid_req.satisfied
    end

    test "spec_valid reflects inline validation result from sync" do
      {scope, tmp_dir, component} = setup_component("schema")

      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget.spec.md", spec_content())
      sync!(scope, tmp_dir)

      # FileSync validates inline — check what it produced
      file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/widget.spec.md")
      assert not is_nil(file.valid), "sync should validate spec files inline"

      results = RequirementCalculator.compute_component(scope, reload(scope, component))
      valid_req = find_req(results, "spec_valid")

      # Satisfaction depends on whether the minimal spec passes document validation
      assert valid_req.satisfied == file.valid
    end

    test "spec_valid unsatisfied when file marked invalid" do
      {scope, tmp_dir, component} = setup_component("schema")

      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget.spec.md", spec_content())
      sync!(scope, tmp_dir)

      file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/widget.spec.md")
      {:ok, _} = Files.mark_validated(file, false, %{error: "Missing ## Type section"})

      results = RequirementCalculator.compute_component(scope, reload(scope, component))
      valid_req = find_req(results, "spec_valid")

      refute valid_req.satisfied
      assert valid_req.details.reason =~ "invalid"
    end
  end

  describe "compute_component/2 — default requirements (module type)" do
    test "returns all 6 default requirements for module type" do
      {scope, _tmp_dir, component} = setup_component("module")

      results = RequirementCalculator.compute_component(scope, component)
      names = Enum.map(results, & &1.name)

      assert "spec_file" in names
      assert "spec_valid" in names
      assert "implementation_file" in names
      assert "test_file" in names
      assert "test_spec_alignment" in names
      assert "tests_passing" in names
    end
  end

  describe "context requirements (no container nodes)" do
    test "context type has no context_specs or context_implementation requirements" do
      {scope, _tmp_dir} = setup_project()

      parent = create_component(scope, "MyApp.Accounts", "context")
      results = RequirementCalculator.compute_component(scope, parent)
      names = Enum.map(results, & &1.name)

      refute "context_specs" in names, "context_specs should not exist — replaced by graph edges"
      refute "context_implementation" in names, "context_implementation should not exist — replaced by graph edges"
      assert "spec_file" in names
      assert "review_file" in names
      assert "implementation_file" in names
    end
  end

  # -- Helpers --

  defp setup_project do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    {scope, tmp_dir}
  end

  defp setup_component(type) do
    {scope, tmp_dir} = setup_project()
    component = create_component(scope, "MyApp.Widget", type)
    {scope, tmp_dir, component}
  end

  defp create_component(scope, module_name, type) do
    name = module_name |> String.split(".") |> List.last()

    {:ok, component} =
      Components.create_component(scope, %{
        name: name,
        type: type,
        module_name: module_name
      })

    component
  end

  defp sync!(scope, tmp_dir) do
    {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

    # Backfill component ownership
    CodeMySpec.Files.ComponentSync.sync_from_files(scope, base_dir: tmp_dir)
  end

  defp reload(scope, component) do
    Components.get_component!(scope, component.id)
  end

  defp find_req(results, name) do
    Enum.find(results, &(&1.name == name))
  end

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  defp spec_content(module_name \\ "MyApp.Widget") do
    """
    # #{module_name}

    A test component.

    ## Type

    schema
    """
  end

  defp context_spec_content do
    """
    # MyApp.Accounts

    Account management context.

    ## Type

    context
    """
  end

  defp impl_content(module_name \\ "MyApp.Widget") do
    """
    defmodule #{module_name} do
      @moduledoc false
    end
    """
  end
end
