defmodule CodeMySpec.Requirements.RequirementCalculatorTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.FixBddSpecs
  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.RequirementCalculator
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
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

  # A latch is the one check type where doing the work is not enough, and until
  # now nothing said so. `specs_ready` is set only by `FixBddSpecs.evaluate/2`;
  # a completed spex sweep does not touch it. Three sweeps went green — 213s,
  # one killed at twelve minutes, 393s — and every re-check still answered
  # "specs_ready is not set", which reads as a broken gate rather than a step
  # not yet taken. Three wrong theories came out of that and one was filed as an
  # issue that had to be withdrawn.
  #
  # The message is the whole feature here, so it is what gets asserted.
  describe "a latch that has not been recorded" do
    test "says what sets it, by name, and that re-running analysis will not" do
      scope = full_scope_fixture()

      definition = %{
        name: "bdd_specs_passing",
        check_type: :field_true,
        config: %{field: :specs_ready},
        satisfied_by: FixBddSpecs
      }

      result =
        RequirementCalculator.compute_one(scope, %{id: 1, specs_ready: false}, definition, [])

      refute result.satisfied
      assert result.details.reason =~ "specs_ready is not set"
      assert result.details.reason =~ "FixBddSpecs"
      assert result.details.reason =~ "evaluate_task"
      assert result.details.reason =~ "re-running the analysis will"
    end

    test "a recorded latch just says so" do
      scope = full_scope_fixture()

      definition = %{
        name: "bdd_specs_passing",
        check_type: :field_true,
        config: %{field: :specs_ready},
        satisfied_by: FixBddSpecs
      }

      result =
        RequirementCalculator.compute_one(scope, %{id: 1, specs_ready: true}, definition, [])

      assert result.satisfied
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
    ComponentSync.sync_from_files(scope, base_dir: tmp_dir)
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

  defp impl_content(module_name \\ "MyApp.Widget") do
    """
    defmodule #{module_name} do
      @moduledoc false
    end
    """
  end
end
