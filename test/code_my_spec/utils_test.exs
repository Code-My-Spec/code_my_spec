defmodule CodeMySpec.UtilsTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Utils

  describe "component_files/2" do
    setup do
      project = %Project{
        id: Ecto.UUID.generate(),
        account_id: Ecto.UUID.generate(),
        name: "Code My Spec",
        module_name: "CodeMySpec"
      }

      {:ok, project: project}
    end

    test "handles sibling namespace modules correctly", %{project: project} do
      # CodeMySpecCli is a sibling namespace, not a child of CodeMySpec
      component = %Component{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        name: "ValidateEdits",
        module_name: "CodeMySpecCli.Hooks.ValidateEdits",
        type: "context"
      }

      files = Utils.component_files(component, project)

      # Should NOT have extra "code_my_spec/" prefix
      assert files.code_file == "lib/code_my_spec_cli/hooks/validate_edits.ex"
      assert files.test_file == "test/code_my_spec_cli/hooks/validate_edits_test.exs"
      assert files.spec_file == "docs/spec/code_my_spec_cli/hooks/validate_edits.spec.md"
    end

    test "handles project-prefixed modules correctly", %{project: project} do
      component = %Component{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        name: "Documents",
        module_name: "CodeMySpec.Documents",
        type: "context"
      }

      files = Utils.component_files(component, project)

      assert files.code_file == "lib/code_my_spec/documents.ex"
      assert files.test_file == "test/code_my_spec/documents_test.exs"
      assert files.spec_file == "docs/spec/code_my_spec/documents.spec.md"
    end

    test "includes review_file for context types", %{project: project} do
      component = %Component{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        name: "Documents",
        module_name: "CodeMySpec.Documents",
        type: "context"
      }

      files = Utils.component_files(component, project)

      assert files.review_file == "docs/spec/code_my_spec/documents/design_review.md"
    end

    test "includes review_file for coordination_context types", %{project: project} do
      component = %Component{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        name: "Sessions",
        module_name: "CodeMySpec.Sessions",
        type: "coordination_context"
      }

      files = Utils.component_files(component, project)

      assert files.review_file == "docs/spec/code_my_spec/sessions/design_review.md"
    end
  end

  describe "changeset_error_to_string/1" do
    test "handles Ecto.Enum type errors without crashing" do
      alias CodeMySpec.Stories.Story

      # Create a changeset with an invalid type that will trigger an Ecto.Enum validation error
      changeset =
        Story.changeset(
          %Story{},
          %{
            title: "Finalize",
            description: "Test step",
            acceptance_criteria: ["ProjectSetupSessions.Steps.Finalize"],
            status: "fuck"
          }
        )

      # This should not crash with Protocol.UndefinedError
      error_string = Utils.changeset_error_to_string(changeset)

      # Should contain the field name and indicate it's invalid
      assert error_string =~ "status"
      assert error_string =~ "is invalid"
    end
  end
end
