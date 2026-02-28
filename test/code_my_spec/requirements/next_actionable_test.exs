defmodule CodeMySpec.Requirements.NextActionableTest do
  use CodeMySpec.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components.ComponentRepository
  alias CodeMySpec.Requirements

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    %{scope: scope, project: project}
  end

  describe "next_actionable/2" do
    test "fresh schema component returns spec_file (ComponentSpec)", %{scope: scope} do
      component = component_fixture(scope, %{type: "schema"}) |> reload(scope)
      result = Requirements.next_actionable(scope, component)

      # Only spec_file should be actionable — it has no prereqs
      assert Map.keys(result) == [CodeMySpec.AgentTasks.ComponentSpec]
      defns = result[CodeMySpec.AgentTasks.ComponentSpec]
      assert length(defns) == 1
      assert hd(defns).name == "spec_file"
    end

    test "fresh genserver component returns spec_file (ComponentSpec)", %{scope: scope} do
      component = component_fixture(scope, %{type: "genserver"}) |> reload(scope)
      result = Requirements.next_actionable(scope, component)

      assert Map.keys(result) == [CodeMySpec.AgentTasks.ComponentSpec]
      defns = result[CodeMySpec.AgentTasks.ComponentSpec]
      assert length(defns) == 1
      assert hd(defns).name == "spec_file"
    end

    test "component with spec_file satisfied returns spec_valid and test_file", %{scope: scope} do
      component = component_fixture(scope, %{type: "genserver"})

      # Satisfy spec_file
      {:ok, _} =
        Requirements.create_requirement(scope, component, %{
          name: "spec_file",
          artifact_type: :specification,
          description: "Component specification file exists",
          checker_module: CodeMySpec.Requirements.FileExistenceChecker,
          satisfied: true,
          score: 1.0,
          checked_at: DateTime.utc_now()
        })

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      # spec_valid depends on spec_file (met) → actionable
      # test_file depends on spec_valid (not yet met) → NOT actionable
      # implementation_file depends on spec_valid + dependencies_satisfied → NOT actionable
      assert Map.keys(result) == [CodeMySpec.AgentTasks.ComponentSpec]
      defns = result[CodeMySpec.AgentTasks.ComponentSpec]
      assert length(defns) == 1
      assert hd(defns).name == "spec_valid"
    end

    test "component with spec_file + spec_valid satisfied unlocks test_file and implementation_file",
         %{scope: scope} do
      component = component_fixture(scope, %{type: "genserver"})

      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      # test_file prereq: spec_valid (met) → actionable (ComponentTest)
      # implementation_file prereq: spec_valid (met) + dependencies_satisfied
      # (vacuously met for genserver) → actionable (ComponentCode)
      task_modules = Map.keys(result) |> Enum.sort()

      assert CodeMySpec.AgentTasks.ComponentCode in task_modules
      assert CodeMySpec.AgentTasks.ComponentTest in task_modules

      test_defns = result[CodeMySpec.AgentTasks.ComponentTest]
      test_names = Enum.map(test_defns, & &1.name) |> Enum.sort()
      assert "test_file" in test_names
    end

    test "context with nothing satisfied returns only spec_file (ContextSpec)", %{scope: scope} do
      component = component_fixture(scope, %{type: "context"}) |> reload(scope)
      result = Requirements.next_actionable(scope, component)

      assert Map.keys(result) == [CodeMySpec.AgentTasks.ContextSpec]
      defns = result[CodeMySpec.AgentTasks.ContextSpec]
      assert length(defns) == 1
      assert hd(defns).name == "spec_file"
    end

    test "context implementation_file requires children_implementations to be met", %{
      scope: scope
    } do
      component = component_fixture(scope, %{type: "context"})

      # Satisfy everything up through review_valid but NOT children_implementations
      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"children_designs", :hierarchy},
            {"review_file", :review},
            {"review_valid", :review},
            {"dependencies_satisfied", :dependencies}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      # implementation_file prereqs: children_implementations + dependencies_satisfied
      # children_implementations is NOT satisfied → implementation_file is NOT actionable
      # test_file prereqs: children_implementations → NOT actionable either
      # BUT children_implementations itself IS actionable (prereqs met, satisfied_by set)

      all_names =
        result
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.name)

      refute "implementation_file" in all_names
      refute "test_file" in all_names

      # children_implementations is now actionable → dispatches to ContextImplementation
      assert CodeMySpec.AgentTasks.ContextImplementation in Map.keys(result)

      impl_defns = result[CodeMySpec.AgentTasks.ContextImplementation]
      impl_names = Enum.map(impl_defns, & &1.name)
      assert "children_implementations" in impl_names
    end

    test "context with children_implementations + deps satisfied unlocks impl and test", %{
      scope: scope
    } do
      component = component_fixture(scope, %{type: "context"})

      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"children_designs", :hierarchy},
            {"review_file", :review},
            {"review_valid", :review},
            {"children_implementations", :hierarchy},
            {"dependencies_satisfied", :dependencies}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      all_names =
        result
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.name)

      assert "implementation_file" in all_names
      assert "test_file" in all_names
    end

    test "fully satisfied component returns empty map", %{scope: scope} do
      component = component_fixture(scope, %{type: "schema"})

      # Schema requirements: spec_file, spec_valid, implementation_file
      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"implementation_file", :code}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      assert result == %{}
    end

    test "meta requirements (satisfied_by: nil) are excluded", %{scope: scope} do
      component = component_fixture(scope, %{type: "genserver"})

      # Satisfy all prereqs so dependencies_satisfied would be "actionable"
      # if it had a satisfied_by — but it doesn't (satisfied_by: nil)
      # tests_passing now has satisfied_by: ComponentCode, so it IS included
      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"test_file", :tests},
            {"test_spec_alignment", :tests},
            {"implementation_file", :code}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      all_names =
        result |> Map.values() |> List.flatten() |> Enum.map(& &1.name)

      # tests_passing has satisfied_by: ComponentCode → included
      assert "tests_passing" in all_names
      # dependencies_satisfied has satisfied_by: nil → excluded
      refute "dependencies_satisfied" in all_names
    end

    test "vacuously met: schema has no dependencies_satisfied so implementation_file prereq is met",
         %{scope: scope} do
      component = component_fixture(scope, %{type: "schema"})

      # Schema: spec_file, spec_valid, implementation_file
      # implementation_file prereqs: ["spec_valid", "dependencies_satisfied"]
      # Schema has NO dependencies_satisfied req → vacuously met

      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      all_names =
        result |> Map.values() |> List.flatten() |> Enum.map(& &1.name)

      assert "implementation_file" in all_names
    end

    test "live_context children_implementations actionable when children_designs met (review_valid vacuous)",
         %{scope: scope} do
      component = component_fixture(scope, %{type: "live_context"})

      # live_context has: spec_file, spec_valid, children_designs,
      #   children_implementations, dependencies_satisfied
      # children_implementations prereqs: ["children_designs", "review_valid"]
      # review_valid is NOT in live_context definitions → vacuously met
      # So satisfying children_designs (+ its prereq spec_valid) should unlock it
      for {name, artifact_type} <- [
            {"spec_file", :specification},
            {"spec_valid", :specification},
            {"children_designs", :hierarchy}
          ] do
        {:ok, _} =
          Requirements.create_requirement(scope, component, %{
            name: name,
            artifact_type: artifact_type,
            description: "test",
            checker_module: CodeMySpec.Requirements.FileExistenceChecker,
            satisfied: true,
            score: 1.0,
            checked_at: DateTime.utc_now()
          })
      end

      component = reload_component_with_requirements(scope, component)
      result = Requirements.next_actionable(scope, component)

      assert CodeMySpec.AgentTasks.ContextImplementation in Map.keys(result)

      impl_defns = result[CodeMySpec.AgentTasks.ContextImplementation]
      impl_names = Enum.map(impl_defns, & &1.name)
      assert "children_implementations" in impl_names
    end

    test "liveview with nothing satisfied returns spec_file (LiveViewSpec)", %{scope: scope} do
      component = component_fixture(scope, %{type: "liveview"}) |> reload(scope)
      result = Requirements.next_actionable(scope, component)

      assert Map.keys(result) == [CodeMySpec.AgentTasks.LiveViewSpec]
      defns = result[CodeMySpec.AgentTasks.LiveViewSpec]
      assert length(defns) == 1
      assert hd(defns).name == "spec_file"
    end
  end

  # Helpers

  defp reload(component, scope) do
    ComponentRepository.get_component(scope, component.id)
  end

  defp reload_component_with_requirements(scope, component), do: reload(component, scope)
end
