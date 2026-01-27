defmodule CodeMySpec.McpServers.Architecture.Tools.GetSpecTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.McpServers.Architecture.Tools.GetSpec
  alias CodeMySpec.Components
  alias Hermes.Server.Frame
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "GetSpec tool" do
    test "retrieves spec by module name" do
      scope = full_scope_fixture()

      # Create spec file
      spec_path = "docs/spec/test_app/my_module.spec.md"
      File.mkdir_p!(Path.dirname(spec_path))

      spec_content = """
      # TestApp.MyModule

      This is a test module.

      ## Dependencies

      - TestApp.Dependency1
      - TestApp.Dependency2

      ## Functions

      ### my_function/1

      Does something useful.
      """

      File.write!(spec_path, spec_content)

      # Create component in DB
      Components.upsert_component(scope, %{
        module_name: "TestApp.MyModule",
        type: "module",
        name: "MyModule",
        description: "This is a test module."
      })

      params = %{module_name: "TestApp.MyModule"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      # Parse response
      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      # Verify component metadata
      assert data["component"]["module_name"] == "TestApp.MyModule"
      assert data["component"]["type"] == "module"
      assert data["component"]["name"] == "MyModule"

      # Verify spec path
      assert data["spec_path"] == spec_path

      # Verify spec content
      assert data["spec_content"] == spec_content

      # Cleanup
      File.rm_rf!("docs/spec/test_app")
    end

    test "retrieves spec by component ID" do
      scope = full_scope_fixture()

      # Create spec file
      spec_path = "docs/spec/test_app/by_id.spec.md"
      File.mkdir_p!(Path.dirname(spec_path))

      spec_content = """
      # TestApp.ById

      Retrieved by ID.

      ## Dependencies

      - None
      """

      File.write!(spec_path, spec_content)

      # Create component in DB
      component =
        Components.upsert_component(scope, %{
          module_name: "TestApp.ById",
          type: "context",
          name: "ById",
          description: "Retrieved by ID."
        })

      params = %{component_id: component.id}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.isError == false

      # Parse response
      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["component"]["id"] == component.id
      assert data["component"]["module_name"] == "TestApp.ById"
      assert data["spec_content"] == spec_content

      # Cleanup
      File.rm_rf!("docs/spec/test_app")
    end

    test "includes dependency information in response" do
      scope = full_scope_fixture()

      # Create dependency components
      dep1 =
        Components.upsert_component(scope, %{
          module_name: "TestApp.Dep1",
          type: "module",
          name: "Dep1"
        })

      dep2 =
        Components.upsert_component(scope, %{
          module_name: "TestApp.Dep2",
          type: "module",
          name: "Dep2"
        })

      # Create main component
      main =
        Components.upsert_component(scope, %{
          module_name: "TestApp.Main",
          type: "context",
          name: "Main"
        })

      # Create dependencies
      Components.create_dependency(scope, %{
        source_component_id: main.id,
        target_component_id: dep1.id
      })

      Components.create_dependency(scope, %{
        source_component_id: main.id,
        target_component_id: dep2.id
      })

      # Create spec file
      spec_path = "docs/spec/test_app/main.spec.md"
      File.mkdir_p!(Path.dirname(spec_path))
      File.write!(spec_path, "# TestApp.Main\n\nMain component")

      params = %{module_name: "TestApp.Main"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.isError == false

      # Parse response
      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      # Verify dependencies are included
      assert data["component"]["dependencies"] == ["TestApp.Dep1", "TestApp.Dep2"]

      # Cleanup
      File.rm_rf!("docs/spec/test_app")
    end

    test "includes dependent components in response" do
      scope = full_scope_fixture()

      # Create main component
      base =
        Components.upsert_component(scope, %{
          module_name: "TestApp.Base",
          type: "module",
          name: "Base"
        })

      # Create dependent components
      dependent1 =
        Components.upsert_component(scope, %{
          module_name: "TestApp.Dependent1",
          type: "context",
          name: "Dependent1"
        })

      dependent2 =
        Components.upsert_component(scope, %{
          module_name: "TestApp.Dependent2",
          type: "context",
          name: "Dependent2"
        })

      # Create dependencies (dependents depend on base)
      Components.create_dependency(scope, %{
        source_component_id: dependent1.id,
        target_component_id: base.id
      })

      Components.create_dependency(scope, %{
        source_component_id: dependent2.id,
        target_component_id: base.id
      })

      # Create spec file
      spec_path = "docs/spec/test_app/base.spec.md"
      File.mkdir_p!(Path.dirname(spec_path))
      File.write!(spec_path, "# TestApp.Base\n\nBase component")

      params = %{module_name: "TestApp.Base"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.isError == false

      # Parse response
      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      # Verify dependents are included
      dependents = data["component"]["dependents"]
      assert "TestApp.Dependent1" in dependents
      assert "TestApp.Dependent2" in dependents

      # Cleanup
      File.rm_rf!("docs/spec/test_app")
    end

    test "returns error when neither module_name nor component_id provided" do
      scope = full_scope_fixture()

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "returns error when component not found by module_name" do
      scope = full_scope_fixture()

      params = %{module_name: "TestApp.NonExistent"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "returns error when component not found by ID" do
      scope = full_scope_fixture()

      params = %{component_id: "00000000-0000-0000-0000-000000000000"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "returns component info with spec_exists: false when spec file doesn't exist" do
      scope = full_scope_fixture()

      # Create component but no spec file
      Components.upsert_component(scope, %{
        module_name: "TestApp.NoSpecFile",
        type: "module",
        name: "NoSpecFile"
      })

      params = %{module_name: "TestApp.NoSpecFile"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.type == :tool
      # Not an error - returns component info with spec_exists: false
      assert response.isError == false

      # Parse the response content
      [content] = response.content
      data = Jason.decode!(content["text"])
      assert data["spec_exists"] == false
      assert data["message"] == "Spec file does not exist yet. Use create_spec to create it."
      assert data["component"]["module_name"] == "TestApp.NoSpecFile"
    end

    test "returns error when scope is invalid" do
      params = %{module_name: "TestApp.Invalid"}
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true
    end

    test "handles spec files with complex content" do
      scope = full_scope_fixture()

      # Create spec file with multiple sections
      spec_path = "docs/spec/test_app/complex.spec.md"
      File.mkdir_p!(Path.dirname(spec_path))

      spec_content = """
      # TestApp.Complex

      Complex module with many sections.

      ## Dependencies

      - TestApp.Dep1
      - TestApp.Dep2

      ## Delegates

      - func1/1: Target.func1/1

      ## Fields

      | Field | Type | Required |
      |-------|------|----------|
      | id    | int  | Yes      |

      ## Functions

      ### func1/1

      First function.

      ```elixir
      @spec func1(term()) :: :ok
      ```

      **Process**:
      1. Step one
      2. Step two

      **Test Assertions**:
      - assertion one
      - assertion two

      ### func2/2

      Second function.
      """

      File.write!(spec_path, spec_content)

      # Create component
      Components.upsert_component(scope, %{
        module_name: "TestApp.Complex",
        type: "module",
        name: "Complex"
      })

      params = %{module_name: "TestApp.Complex"}
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetSpec.execute(params, frame)
      assert response.isError == false

      # Parse response
      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      # Verify full content is returned
      returned_content = data["spec_content"]
      assert returned_content =~ "## Dependencies"
      assert returned_content =~ "## Delegates"
      assert returned_content =~ "## Fields"
      assert returned_content =~ "## Functions"
      assert returned_content =~ "### func1/1"
      assert returned_content =~ "### func2/2"
      assert returned_content =~ "**Process**:"
      assert returned_content =~ "**Test Assertions**:"

      # Cleanup
      File.rm_rf!("docs/spec/test_app")
    end
  end
end
