defmodule CodeMySpec.DocumentsTest do
  use ExUnit.Case, async: true
  doctest CodeMySpec.Documents

  alias CodeMySpec.Documents

  describe "create_dynamic_document/2" do
    test "creates a valid schema document from markdown" do
      markdown = """
      # UserSchema
      Represents user account entities with authentication credentials.

      ## Fields
      | Field | Type | Required | Description | Constraints |
      |-------|------|----------|-------------|-------------|
      | email | string | Yes | User email address | Unique |
      | name | string | Yes | User full name | Min: 1, Max: 255 |

      ## Dependencies
      - CodeMySpec.MyModule
      """

      {:ok, document} = Documents.create_dynamic_document(markdown, "schema")

      assert document.type == "schema"
      assert is_list(document.sections["fields"])
    end

    test "returns error for missing required sections" do
      markdown = """
      # Incomplete

      ## Purpose
      Only has purpose.
      """

      {:error, error} = Documents.create_dynamic_document(markdown, "schema")

      assert error =~ "Missing required sections"
      assert error =~ "fields"
    end

    test "allows additional sections when allowed_additional_sections is '*'" do
      markdown = """
      # Context
      Does context things.

      ## Entity Ownership
      Owns entities.

      ## Access Patterns
      Scoped access.

      ## Public API
      API functions.

      ## State Management Strategy
      Uses database.

      ## Execution Flow
      Process flow.

      ## Dependencies
      - Some.Module

      ## Components
      Component list.

      ## Test Strategies
      Testing approach.

      ## Test Assertions
      - test assertions

      ## Custom Section
      Extra content allowed for contexts.

      ## Delegates
      - func/1: Other.func/1
      """

      {:ok, document} = Documents.create_dynamic_document(markdown, "dynamic_document")

      assert document.sections["custom section"] == "Extra content allowed for contexts."
    end

    test "rejects additional sections when allowed_additional_sections is []" do
      markdown = """
      # MyModule.Spec

      ## Delegates
      - func/1: Other.func/1

      ## Functions

      ### my_func/1
      Does something.

      ## Dependencies
      - Other.Module

      ## Custom Section
      This should not be allowed for specs!
      """

      {:error, error} = Documents.create_dynamic_document(markdown, "spec")

      assert error =~ "Disallowed sections found"
      assert error =~ "custom section"
    end

    test "allows multiple disallowed sections in error message" do
      markdown = """
      # MyModule.Spec

      ## Delegates
      - func/1: Other.func/1

      ## Functions

      ### my_func/1
      Does something.

      ## Dependencies
      - Other.Module

      ## Custom One
      Not allowed.

      ## Custom Two
      Also not allowed.
      """

      {:error, error} = Documents.create_dynamic_document(markdown, "spec")

      assert error =~ "Disallowed sections found"
      assert error =~ "custom one"
      assert error =~ "custom two"
    end

    test "allows optional sections for spec documents" do
      markdown = """
      # MyModule.Spec

      ## Delegates
      - func/1: Other.func/1

      ## Functions

      ### my_func/1
      Does something.

      ## Dependencies
      - Other.Module

      ## Fields
      | Field | Type | Required |
      |-------|------|----------|
      | name | string | Yes |
      """

      {:ok, document} = Documents.create_dynamic_document(markdown, "spec")

      assert document.type == "spec"
      assert is_list(document.sections["fields"])
    end

    test "validates OR logic - succeeds when first alternative is present" do
      # Create a test document type with OR logic
      markdown = """
      # Test

      ## Delegates
      - func/1: Other.func/1

      ## Dependencies
      - Other.Module

      ## Components
      Component list.
      """

      # Temporarily test with context_spec which has [["delegates", "functions"], "dependencies", "components"]
      {:ok, document} = Documents.create_dynamic_document(markdown, "context_spec")

      assert document.type == "context_spec"
    end

    test "validates OR logic - succeeds when second alternative is present" do
      markdown = """
      # Test

      ## Functions

      ### my_func/1
      Does something.

      ## Dependencies
      - Other.Module

      ## Components
      Component list.
      """

      {:ok, document} = Documents.create_dynamic_document(markdown, "context_spec")

      assert document.type == "context_spec"
    end

    test "validates OR logic - fails when none of the alternatives are present" do
      markdown = """
      # Test

      ## Dependencies
      - Other.Module

      ## Components
      Component list.
      """

      {:error, error} = Documents.create_dynamic_document(markdown, "context_spec")

      assert error =~ "Missing required sections"
      assert error =~ "delegates OR functions"
    end

    test "validates mixed OR and regular required sections" do
      markdown = """
      # Test

      ## Functions

      ### my_func/1
      Does something.

      ## Components
      Component list.
      """

      {:error, error} = Documents.create_dynamic_document(markdown, "context_spec")

      assert error =~ "Missing required sections"
      assert error =~ "dependencies"
      refute error =~ "delegates OR functions"
    end

    test "returns error when document_type is nil" do
      markdown = """
      # MyModule

      ## Functions

      ### my_func/1
      Does something.

      ## Dependencies
      - Other.Module
      """

      assert {:error, error} = Documents.create_dynamic_document(markdown, nil)
      assert error =~ "Document type is required"
    end

    test "returns error when document_type is empty string" do
      markdown = "# MyModule\n\n## Functions\n\n### f/0\nDoes stuff.\n\n## Dependencies\nNone\n"

      assert {:error, error} = Documents.create_dynamic_document(markdown, "")
      assert error =~ "Document type is required"
    end

    test "allows ## Type section in any document type" do
      markdown = """
      # MyModule.Spec

      ## Type

      genserver

      ## Delegates
      - func/1: Other.func/1

      ## Dependencies
      - Other.Module
      """

      assert {:ok, document} = Documents.create_dynamic_document(markdown, "spec")
      assert document.sections["type"] == "genserver"
    end

    test "allows ## Type section in liveview document type" do
      markdown = """
      # MyAppWeb.DashboardLive

      ## Type

      liveview

      ## Route

      `/dashboard`

      ## User Interactions

      - **phx-click="refresh"**: Reload data.

      ## Dependencies

      - MyApp.Accounts

      ## Design

      It looks awesome
      """

      assert {:ok, document} = Documents.create_dynamic_document(markdown, "liveview")
      assert document.sections["type"] == "liveview"
    end
  end

  describe "validate_h1_matches_path/2" do
    test "returns :ok when H1 matches expected module from path" do
      content = """
      # CodeMySpec.Accounts.User

      User module description.
      """

      path = "/some/project/.code_my_spec/spec/code_my_spec/accounts/user.spec.md"

      assert :ok = Documents.validate_h1_matches_path(content, path)
    end

    test "returns error when H1 doesn't match path" do
      content = """
      # User

      Short module name.
      """

      path = "/some/project/.code_my_spec/spec/code_my_spec/accounts/user.spec.md"

      assert {:error, message} = Documents.validate_h1_matches_path(content, path)
      assert message =~ "does not match expected"
      assert message =~ "CodeMySpec.Accounts.User"
    end

    test "returns error when H1 is missing" do
      content = """
      Just some content without an H1.
      """

      path = "/some/project/.code_my_spec/spec/code_my_spec/accounts/user.spec.md"

      assert {:error, message} = Documents.validate_h1_matches_path(content, path)
      assert message =~ "Missing H1 title"
    end

    test "handles nested paths correctly" do
      content = """
      # CodeMySpec.McpServers.Architecture.Tools.GetComponentView

      Nested module.
      """

      path =
        "/project/.code_my_spec/spec/code_my_spec/mcp_servers/architecture/tools/get_component_view.spec.md"

      assert :ok = Documents.validate_h1_matches_path(content, path)
    end
  end

  describe "validate_internal_dependencies/2" do
    setup do
      tmp_dir = System.tmp_dir!() |> Path.join("docs_validation_test_#{:rand.uniform(10000)}")
      File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/spec/code_my_spec/accounts"))
      File.mkdir_p!(Path.join(tmp_dir, "lib/code_my_spec/accounts"))

      # Create a spec file
      File.write!(
        Path.join(tmp_dir, ".code_my_spec/spec/code_my_spec/accounts/user.spec.md"),
        "# CodeMySpec.Accounts.User\n"
      )

      # Create an impl file
      File.write!(
        Path.join(tmp_dir, "lib/code_my_spec/accounts/account.ex"),
        "defmodule CodeMySpec.Accounts.Account do\nend"
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "returns no warnings when all internal dependencies exist", %{tmp_dir: tmp_dir} do
      content = """
      # CodeMySpec.Test

      ## Dependencies

      - CodeMySpec.Accounts.User
      - CodeMySpec.Accounts.Account
      """

      assert {:ok, []} = Documents.validate_internal_dependencies(content, tmp_dir)
    end

    test "returns warnings for missing internal dependencies", %{tmp_dir: tmp_dir} do
      content = """
      # CodeMySpec.Test

      ## Dependencies

      - CodeMySpec.Accounts.User
      - CodeMySpec.Accounts.Missing
      """

      assert {:ok, warnings} = Documents.validate_internal_dependencies(content, tmp_dir)
      assert length(warnings) == 1
      assert hd(warnings) =~ "CodeMySpec.Accounts.Missing"
      assert hd(warnings) =~ "not found"
    end

    test "ignores external dependencies", %{tmp_dir: tmp_dir} do
      content = """
      # CodeMySpec.Test

      ## Dependencies

      - Ecto.Schema
      - Phoenix.LiveView
      - File
      """

      assert {:ok, []} = Documents.validate_internal_dependencies(content, tmp_dir)
    end

    test "handles mixed internal and external dependencies", %{tmp_dir: tmp_dir} do
      content = """
      # CodeMySpec.Test

      ## Dependencies

      - CodeMySpec.Accounts.User
      - Ecto.Repo
      - CodeMySpec.Missing.Module
      """

      assert {:ok, warnings} = Documents.validate_internal_dependencies(content, tmp_dir)
      assert length(warnings) == 1
      assert hd(warnings) =~ "CodeMySpec.Missing.Module"
    end
  end
end
