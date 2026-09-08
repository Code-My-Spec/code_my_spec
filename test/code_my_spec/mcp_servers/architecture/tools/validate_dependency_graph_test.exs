defmodule CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraphTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Architecture.Tools.ValidateDependencyGraph
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns valid when no circular dependencies" do
      scope = full_scope_fixture()

      controller =
        component_fixture(scope, %{module_name: "MyApp.UserController", type: "controller"})

      accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})

      # One-way dependency (healthy)
      dependency_fixture(scope, controller, accounts)

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert %Anubis.Server.Response{type: :tool} = response
      assert response.isError == false

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == true
      assert data["message"] == "No circular dependencies detected"
    end

    test "returns valid when no components exist" do
      scope = full_scope_fixture()

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == true
    end

    test "returns valid when components have no dependencies" do
      scope = full_scope_fixture()

      component_fixture(scope, %{module_name: "MyApp.Isolated1", type: "context"})
      component_fixture(scope, %{module_name: "MyApp.Isolated2", type: "context"})

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == true
    end

    test "detects simple circular dependency (A→B, B→A)" do
      scope = full_scope_fixture()

      comp_a = component_fixture(scope, %{module_name: "MyApp.A", type: "context"})
      comp_b = component_fixture(scope, %{module_name: "MyApp.B", type: "context"})

      # Create circular dependency
      circular_dependency_fixture(scope, comp_a, comp_b)

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert response.isError == false

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == false
      assert data["message"] == "Circular dependencies detected"
      assert is_list(data["cycles"])
      assert length(data["cycles"]) == 1
      # One ring, reported once. The self-join matched it in both
      # directions and counted it twice.
    end

    test "includes component information in cycles" do
      scope = full_scope_fixture()

      comp_a = component_fixture(scope, %{module_name: "MyApp.ServiceA", type: "context"})
      comp_b = component_fixture(scope, %{module_name: "MyApp.ServiceB", type: "context"})

      circular_dependency_fixture(scope, comp_a, comp_b)

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == false

      # Check that cycles include component details
      cycle = List.first(data["cycles"])
      assert Map.has_key?(cycle, "components")
      assert Map.has_key?(cycle, "path")
      assert is_list(cycle["components"])
      assert is_list(cycle["path"])
    end

    test "detects multiple separate circular dependencies" do
      scope = full_scope_fixture()

      # First circle: A↔B
      comp_a = component_fixture(scope, %{module_name: "MyApp.A", type: "context"})
      comp_b = component_fixture(scope, %{module_name: "MyApp.B", type: "context"})
      circular_dependency_fixture(scope, comp_a, comp_b)

      # Second circle: C↔D
      comp_c = component_fixture(scope, %{module_name: "MyApp.C", type: "context"})
      comp_d = component_fixture(scope, %{module_name: "MyApp.D", type: "context"})
      circular_dependency_fixture(scope, comp_c, comp_d)

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == false
      # Should detect 4 cycles (2 bidirectional dependencies = 4 edges in cycles)
      assert length(data["cycles"]) == 2
      # Two rings, not four. Each used to arrive twice, once per direction of
      # the self-join that found them.
    end

    test "handles complex dependency graph with one cycle" do
      scope = full_scope_fixture()

      # credo:disable-for-next-line ExSlop.Check.Readability.ObviousComment
      # Create a chain: A→B→C→D
      comp_a = component_fixture(scope, %{module_name: "MyApp.A", type: "controller"})
      comp_b = component_fixture(scope, %{module_name: "MyApp.B", type: "context"})
      comp_c = component_fixture(scope, %{module_name: "MyApp.C", type: "context"})
      comp_d = component_fixture(scope, %{module_name: "MyApp.D", type: "schema"})

      dependency_fixture(scope, comp_a, comp_b)
      dependency_fixture(scope, comp_b, comp_c)
      dependency_fixture(scope, comp_c, comp_d)

      # Add one circular dependency: B↔C
      dependency_fixture(scope, comp_c, comp_b)

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == false
      assert length(data["cycles"]) == 1
      # One ring, reported once. The self-join matched it in both
      # directions and counted it twice.
    end

    test "returns error for invalid scope" do
      params = %{}
      frame = %Frame{assigns: %{}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert response.type == :tool
      assert response.isError == true
    end

    test "validates complex architecture with no cycles" do
      scope = full_scope_fixture()

      # Create realistic architecture: controllers → contexts → schemas
      user_controller =
        component_fixture(scope, %{module_name: "MyApp.UserController", type: "controller"})

      post_controller =
        component_fixture(scope, %{module_name: "MyApp.PostController", type: "controller"})

      accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})
      blog = component_fixture(scope, %{module_name: "MyApp.Blog", type: "context"})

      user_schema =
        component_fixture(scope, %{module_name: "MyApp.Accounts.User", type: "schema"})

      post_schema = component_fixture(scope, %{module_name: "MyApp.Blog.Post", type: "schema"})

      # Controllers depend on contexts
      dependency_fixture(scope, user_controller, accounts)
      dependency_fixture(scope, post_controller, blog)

      # Contexts depend on schemas
      dependency_fixture(scope, accounts, user_schema)
      dependency_fixture(scope, blog, post_schema)

      # Blog depends on Accounts (for user references)
      dependency_fixture(scope, blog, accounts)

      params = %{}
      frame = %Frame{assigns: %{current_scope: scope}}

      {:reply, response, _frame} = ValidateDependencyGraph.execute(params, frame)

      assert [%{"type" => "text", "text" => json_text}] = response.content
      data = Jason.decode!(json_text)

      assert data["valid"] == true
      assert data["message"] == "No circular dependencies detected"
    end
  end
end
