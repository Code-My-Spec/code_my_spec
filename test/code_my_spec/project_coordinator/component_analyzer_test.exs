defmodule CodeMySpec.ProjectCoordinator.ComponentAnalyzerTest do
  use CodeMySpecTest.DataCase
  doctest CodeMySpec.ProjectCoordinator.ComponentAnalyzer

  alias CodeMySpec.ProjectCoordinator.ComponentAnalyzer
  alias CodeMySpec.Components.{Component, ComponentStatus}
  alias CodeMySpec.Tests.{TestResult, TestError}
  alias CodeMySpec.ComponentsFixtures
  alias CodeMySpec.UsersFixtures

  describe "analyze_components/4" do
    test "returns component status for components with all files existing and tests passing" do
      scope = UsersFixtures.full_scope_fixture()

      # Create component using fixture which will generate deterministic UUID
      created_component =
        ComponentsFixtures.component_fixture(scope, %{
          name: "Users",
          module_name: "MyApp.Users",
          type: "context"
        })

      # Fetch component with proper preloads
      component = CodeMySpec.Components.get_component(scope, created_component.id)

      components = [component]

      file_list = [
        ".code_my_spec/design/my_app/users.md",
        "lib/my_app/users.ex",
        "test/my_app/users_test.exs"
      ]

      failures = []

      result =
        ComponentAnalyzer.analyze_components(components, file_list, failures,
          scope: scope,
          persist: false
        )

      assert [%Component{id: id, component_status: %ComponentStatus{} = status}] = result
      assert id == component.id
      assert status.design_exists == true
      assert status.code_exists == true
      assert status.test_exists == true
      assert status.test_status == :passing
    end

    test "returns component status for components with missing files" do
      scope = UsersFixtures.full_scope_fixture()

      # Create component using fixture
      created_component =
        ComponentsFixtures.component_fixture(scope, %{
          name: "Users",
          module_name: "MyApp.Users",
          type: "context"
        })

      # Fetch component with proper preloads
      component = CodeMySpec.Components.get_component(scope, created_component.id)

      components = [component]

      file_list = [
        # Only code file exists
        "lib/my_app/users.ex"
      ]

      failures = []

      result =
        ComponentAnalyzer.analyze_components(components, file_list, failures,
          scope: scope,
          persist: false
        )

      assert [%Component{id: id, component_status: %ComponentStatus{} = status}] = result
      assert id == component.id
      assert status.design_exists == false
      assert status.code_exists == true
      assert status.test_exists == false
      assert status.test_status == :not_run
    end

    test "returns component status for components with failing tests" do
      scope = UsersFixtures.full_scope_fixture()

      # Create component using fixture
      created_component =
        ComponentsFixtures.component_fixture(scope, %{
          name: "Users",
          module_name: "MyApp.Users",
          type: "context"
        })

      # Fetch component with proper preloads
      component = CodeMySpec.Components.get_component(scope, created_component.id)

      components = [component]

      file_list = [
        ".code_my_spec/design/my_app/users.md",
        "lib/my_app/users.ex",
        "test/my_app/users_test.exs"
      ]

      failures = [
        %TestResult{
          title: "validates email",
          full_title: "MyApp.UsersTest validates email",
          status: :failed,
          error: %TestError{
            file: "test/my_app/users_test.exs",
            line: 15,
            message: "Expected true, got false"
          }
        }
      ]

      result =
        ComponentAnalyzer.analyze_components(components, file_list, failures,
          scope: scope,
          persist: false
        )

      assert [%Component{id: id, component_status: %ComponentStatus{} = status}] = result
      assert id == component.id
      assert status.design_exists == true
      assert status.code_exists == true
      assert status.test_exists == true
      assert status.test_status == :failing
    end

    test "handles multiple components" do
      scope = UsersFixtures.full_scope_fixture()

      # Create components using fixtures
      created_users =
        ComponentsFixtures.component_fixture(scope, %{
          name: "Users",
          module_name: "MyApp.Users",
          type: "context"
        })

      created_posts =
        ComponentsFixtures.component_fixture(scope, %{
          name: "Posts",
          module_name: "MyApp.Posts",
          type: "context"
        })

      # Fetch components with proper preloads
      users = CodeMySpec.Components.get_component(scope, created_users.id)
      posts = CodeMySpec.Components.get_component(scope, created_posts.id)

      components = [users, posts]

      file_list = [
        ".code_my_spec/design/my_app/users.md",
        "lib/my_app/users.ex",
        "test/my_app/users_test.exs",
        # Posts missing design and test
        "lib/my_app/posts.ex"
      ]

      failures = []

      result =
        ComponentAnalyzer.analyze_components(components, file_list, failures,
          scope: scope,
          persist: false
        )

      assert length(result) == 2

      # Find components by ID (order-independent)
      users_result = Enum.find(result, fn c -> c.id == users.id end)
      posts_result = Enum.find(result, fn c -> c.id == posts.id end)

      assert %Component{component_status: %ComponentStatus{} = users_status} = users_result
      assert %Component{component_status: %ComponentStatus{} = posts_status} = posts_result

      assert users_status.design_exists == true
      assert users_status.code_exists == true
      assert users_status.test_exists == true
      assert users_status.test_status == :passing

      assert posts_status.design_exists == false
      assert posts_status.code_exists == true
      assert posts_status.test_exists == false
      assert posts_status.test_status == :not_run
    end

    test "ignores test results from other files" do
      scope = UsersFixtures.full_scope_fixture()

      # Create component using fixture
      created_component =
        ComponentsFixtures.component_fixture(scope, %{
          name: "Users",
          module_name: "MyApp.Users",
          type: "context"
        })

      # Fetch component with proper preloads
      component = CodeMySpec.Components.get_component(scope, created_component.id)

      components = [component]

      file_list = [
        "lib/my_app/users.ex",
        "test/my_app/users_test.exs"
      ]

      failures = [
        # This failure is from a different file, should be ignored
        %TestResult{
          title: "validates post",
          full_title: "MyApp.PostsTest validates post",
          status: :failed,
          error: %TestError{
            file: "test/my_app/posts_test.exs",
            line: 10,
            message: "Expected valid, got invalid"
          }
        }
      ]

      result =
        ComponentAnalyzer.analyze_components(components, file_list, failures,
          scope: scope,
          persist: false
        )

      assert [%Component{id: id, component_status: %ComponentStatus{} = status}] = result
      assert id == component.id
      assert status.design_exists == false
      assert status.code_exists == true
      assert status.test_exists == true
      # Should be passing, not failing
      assert status.test_status == :passing
    end

    test "handles nested module names correctly" do
      scope = UsersFixtures.full_scope_fixture()

      # Create component using fixture
      created_component =
        ComponentsFixtures.component_fixture(scope, %{
          name: "UserProfile",
          module_name: "MyApp.Accounts.UserProfile",
          type: "schema"
        })

      # Fetch component with proper preloads
      component = CodeMySpec.Components.get_component(scope, created_component.id)

      components = [component]

      file_list = [
        ".code_my_spec/design/my_app/accounts/user_profile.md",
        "lib/my_app/accounts/user_profile.ex",
        "test/my_app/accounts/user_profile_test.exs"
      ]

      failures = []

      result =
        ComponentAnalyzer.analyze_components(components, file_list, failures,
          scope: scope,
          persist: false
        )

      assert [%Component{id: id, component_status: %ComponentStatus{} = status}] = result
      assert id == component.id
      assert status.design_exists == true
      assert status.code_exists == true
      assert status.test_exists == true
      assert status.test_status == :passing
    end

    test "builds nested dependency trees with actual Component and Dependency records" do
      # Create components with actual database records and dependencies
      scope = UsersFixtures.full_scope_fixture()

      {_parent, _child} =
        ComponentsFixtures.component_with_dependencies_fixture(scope, %{
          name: "UserContext",
          module_name: "MyApp.UserContext"
        })

      # Use the proper Components context function that preloads dependencies
      components = CodeMySpec.Components.list_components_with_dependencies(scope)

      # Create file list that matches some expected files
      file_list = [
        ".code_my_spec/design/my_app/user_context.md",
        "lib/my_app/user_context.ex",
        "test/my_app/user_context_test.exs"
      ]

      failures = []

      result =
        ComponentAnalyzer.analyze_components(components, file_list, failures,
          scope: scope,
          persist: false
        )

      assert length(result) == 2

      # Find parent and child components (parent has dependencies, child doesn't)
      parent_result = Enum.find(result, fn c -> c.name == "UserContext" end)
      child_result = Enum.find(result, fn c -> c.name != "UserContext" end)

      # Verify parent has nested dependency with analyzed child
      assert %Component{
               name: "UserContext",
               component_status: %ComponentStatus{} = parent_status,
               dependencies: [%Component{component_status: %ComponentStatus{}}]
             } = parent_result

      # Verify child has empty dependencies
      assert %Component{
               dependencies: []
             } = child_result

      # Verify component statuses are computed
      assert parent_status.design_exists == true
      assert parent_status.code_exists == true
      assert parent_status.test_exists == true
    end

    test "returns empty list for empty components list" do
      scope = UsersFixtures.full_scope_fixture()

      result =
        ComponentAnalyzer.analyze_components([], [], [],
          scope: scope,
          persist: false
        )

      assert result == []
    end
  end
end
