defmodule CodeMySpec.Requirements.DocumentValidityCheckerTest do
  use CodeMySpec.DataCase
  doctest CodeMySpec.Requirements.DocumentValidityChecker

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Requirements.DocumentValidityChecker
  alias CodeMySpec.Requirements.RequirementDefinition

  @valid_context_spec_content """
  # TestContext

  ## Delegates
  - func/1: Other.func/1

  ## Dependencies
  - Some.Module

  ## Components
  ### ComponentOne
  Description of component.
  """

  @valid_spec_content """
  # TestModule

  ## Delegates
  - func/1: Other.func/1

  ## Dependencies
  - Some.Module
  """

  @valid_schema_content """
  # UserSchema
  Represents user entities.

  ## Fields
  | Field | Type | Required | Description | Constraints |
  |-------|------|----------|-------------|-------------|
  | email | string | Yes | User email | Unique |
  """

  @invalid_spec_content """
  # Incomplete

  ## Purpose
  Only has purpose.
  """

  describe "check/2 with valid documents" do
    test "validates a valid context_spec document" do
      scope = full_scope_fixture()
      module_name = "TestApp.TestContextSpec"
      spec_path = create_spec_file(module_name, @valid_context_spec_content, scope.active_project)

      component = %Component{module_name: module_name, type: "context"}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ContextSpec"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)

      assert result.satisfied == true
      assert result.name == :spec_valid
      assert result.artifact_type == :document_validity
      assert result.details.status == "Document is valid"
      assert result.details.document_type == "context_spec"

      cleanup_spec_file(spec_path, scope.active_project)
    end

    test "validates a valid spec document" do
      scope = full_scope_fixture()
      module_name = "TestApp.TestSpec"
      spec_path = create_spec_file(module_name, @valid_spec_content, scope.active_project)

      component = %Component{module_name: module_name, type: "component"}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ComponentSpecSessions"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)

      assert result.satisfied == true
      assert result.details.document_type == "spec"

      cleanup_spec_file(spec_path, scope.active_project)
    end

    test "validates a valid schema document" do
      scope = full_scope_fixture()
      module_name = "TestApp.TestSchema"
      spec_path = create_spec_file(module_name, @valid_schema_content, scope.active_project)

      component = %Component{module_name: module_name, type: "schema"}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ComponentSpecSessions"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)
      assert result.satisfied == true
      assert result.details.document_type == "schema"

      cleanup_spec_file(spec_path, scope.active_project)
    end
  end

  describe "check/2 with invalid documents" do
    test "returns error for document missing required sections" do
      scope = full_scope_fixture()
      module_name = "TestApp.InvalidSpec"
      spec_path = create_spec_file(module_name, @invalid_spec_content, scope.active_project)

      component = %Component{module_name: module_name, type: "component"}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ComponentSpecSessions"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason == "Document validation failed"
      assert result.details.error =~ "Missing required sections"
      assert result.details.document_type == "spec"

      cleanup_spec_file(spec_path, scope.active_project)
    end

    test "returns error for document with disallowed sections" do
      scope = full_scope_fixture()

      content = """
      # TestModule

      ## Delegates
      - func/1: Other.func/1

      ## Dependencies
      - Some.Module

      ## Custom Section
      Not allowed for specs!
      """

      module_name = "TestApp.DisallowedSpec"
      spec_path = create_spec_file(module_name, content, scope.active_project)

      component = %Component{module_name: module_name, type: "component"}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ComponentSpecSessions"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason == "Document validation failed"
      assert result.details.error =~ "Disallowed sections found"

      cleanup_spec_file(spec_path, scope.active_project)
    end
  end

  describe "check/2 with missing files" do
    test "returns error when file does not exist" do
      scope = full_scope_fixture()
      component = %Component{module_name: "TestApp.NonexistentModule", type: "component"}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ComponentSpecSessions"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason =~ "Failed to read spec file"
    end
  end

  describe "check/2 with missing document_type" do
    test "returns error when document_type is not specified" do
      scope = full_scope_fixture()
      component = %Component{module_name: "TestApp.SomeModule", type: nil}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ComponentSpecSessions"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)

      assert result.satisfied == false
      assert result.details.reason =~ "Failed to read spec file"
    end
  end

  describe "result structure" do
    test "includes all required fields" do
      scope = full_scope_fixture()
      module_name = "TestApp.ResultStructureTest"
      spec_path = create_spec_file(module_name, @valid_spec_content, scope.active_project)

      component = %Component{module_name: module_name, type: "component"}

      requirement_definition = %RequirementDefinition{
        name: :spec_valid,
        artifact_type: :document_validity,
        description: "Document is valid",
        checker: DocumentValidityChecker,
        satisfied_by: "ComponentSpecSessions"
      }

      result = DocumentValidityChecker.check(scope, requirement_definition, component)

      assert Map.has_key?(result, :name)
      assert Map.has_key?(result, :artifact_type)
      assert Map.has_key?(result, :description)
      assert Map.has_key?(result, :checker_module)
      assert Map.has_key?(result, :satisfied_by)
      assert Map.has_key?(result, :satisfied)
      assert Map.has_key?(result, :checked_at)
      assert Map.has_key?(result, :details)

      assert result.artifact_type == :document_validity
      assert result.checker_module == CodeMySpec.Requirements.DocumentValidityChecker

      cleanup_spec_file(spec_path, scope.active_project)
    end
  end

  # Helper functions
  defp create_spec_file(module_name, content, project) do
    component = %Component{module_name: module_name}
    files = CodeMySpec.Utils.component_files(component, project)
    spec_path = files.spec_file

    # Ensure directory exists
    spec_path |> Path.dirname() |> File.mkdir_p!()

    # Write the spec file
    File.write!(spec_path, content)

    spec_path
  end

  defp cleanup_spec_file(spec_path, _project) do
    File.rm(spec_path)

    # Clean up empty directories
    spec_path
    |> Path.dirname()
    |> cleanup_empty_dirs()
  end

  defp cleanup_empty_dirs(dir) do
    case File.ls(dir) do
      {:ok, []} ->
        File.rmdir(dir)
        dir |> Path.dirname() |> cleanup_empty_dirs()

      _ ->
        :ok
    end
  end
end
