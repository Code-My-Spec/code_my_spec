defmodule CodeMySpec.Documents.MarkdownParserTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Documents.Field
  alias CodeMySpec.Documents.Function
  alias CodeMySpec.Documents.MarkdownParser

  describe "parse/1 - basic section extraction" do
    test "extracts H2 sections into map with section names as keys" do
      markdown = """
      # Title

      ## Purpose
      This is the purpose section.

      ## Dependencies
      This is the dependencies section.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert Map.has_key?(sections, "purpose")
      assert Map.has_key?(sections, "dependencies")
    end

    test "lowercases section keys" do
      markdown = """
      # Title

      ## Purpose
      Content here.

      ## Public API
      More content.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert Map.has_key?(sections, "purpose")
      assert Map.has_key?(sections, "public api")
    end

    test "extracts content between H2 headings" do
      markdown = """
      # Title

      ## Purpose
      First paragraph.
      Second paragraph.

      ## Notes
      Some notes content.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections["purpose"] =~ "First paragraph"
      assert sections["purpose"] =~ "Second paragraph"
      assert sections["notes"] =~ "Some notes content"
    end

    test "skips H1 heading" do
      markdown = """
      # MyModule.Name

      **Type**: logic

      This is the description.

      ## Purpose
      Purpose content.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      refute Map.has_key?(sections, "mymodule.name")
      assert Map.has_key?(sections, "purpose")
    end

    test "handles empty sections" do
      markdown = """
      # Title

      ## Purpose

      ## Notes
      Some content.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections["purpose"] == ""
      assert sections["notes"] =~ "Some content"
    end

    test "accepts unclosed code blocks — markdown parsers are lenient" do
      # MDEx treats unclosed fenced code as extending to EOF; there's no
      # concept of "invalid markdown" for well-formed text. The parser
      # returns {:ok, _} — the section extractor just finds no H2s.
      markdown = "```\nunclosed code block"

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections == %{}
    end
  end

  describe "parse/1 - convention-based parser lookup" do
    test "uses FunctionParser for 'functions' section" do
      markdown = """
      # MyModule

      ## Functions

      ### build/1
      Apply dependency tree processing.

      ```elixir
      @spec build([Component.t()]) :: [Component.t()]
      ```

      **Process**:
      1. Sort components
      2. Build tree

      **Test Assertions**:
      - build/1 returns empty list
      - build/1 processes in order
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert [%Function{} = func] = sections["functions"]
      # Verify FunctionParser was used by checking we got a Function struct
      assert func.name == "build/1"
      assert func.description == "Apply dependency tree processing."
      assert func.spec == "@spec build([Component.t()]) :: [Component.t()]"
      # Detailed field extraction is tested in FunctionParserTest
      assert is_list(func.test_assertions)
    end

    test "uses FieldParser for 'fields' section" do
      markdown = """
      # MySchema

      ## Fields

      | Field | Type | Required | Description | Constraints |
      |-------|------|----------|-------------|-------------|
      | id | integer | Yes | Primary key | Auto-generated |
      | name | string | Yes | User name | Min: 1, Max: 255 |
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert [%Field{}, %Field{}] = sections["fields"]
      assert Enum.any?(sections["fields"], &(&1.field == "id"))
      assert Enum.any?(sections["fields"], &(&1.field == "name"))
    end

    test "handles multiple functions in functions section" do
      markdown = """
      # MyModule

      ## Functions

      ### build/1
      First function.

      ### parse/2
      Second function.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert [%Function{}, %Function{}] = sections["functions"]
      assert Enum.any?(sections["functions"], &(&1.name == "build/1"))
      assert Enum.any?(sections["functions"], &(&1.name == "parse/2"))
    end
  end

  describe "parse/1 - fallback to text extraction" do
    test "falls back to text for sections without parsers" do
      markdown = """
      # Title

      ## Purpose
      This is plain text content.

      ## Notes
      Some additional notes.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert is_binary(sections["purpose"])
      assert sections["purpose"] =~ "This is plain text content"
      assert is_binary(sections["notes"])
      assert sections["notes"] =~ "Some additional notes"
    end

    test "handles mixed sections with and without parsers" do
      markdown = """
      # MyModule

      ## Purpose
      Plain text purpose.

      ## Functions

      ### build/1
      Function description.

      ## Dependencies
      - SomeModule
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert is_binary(sections["purpose"])
      assert [%Function{}] = sections["functions"]
      assert is_list(sections["dependencies"])
      assert sections["dependencies"] == ["SomeModule"]
    end
  end

  describe "parse/1 - complex markdown structures" do
    test "extracts ordered lists as formatted text" do
      markdown = """
      # Title

      ## Execution Flow
      1. First step
      2. Second step
      3. Third step
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections["execution flow"] =~ "1. First step"
      assert sections["execution flow"] =~ "2. Second step"
      assert sections["execution flow"] =~ "3. Third step"
    end

    test "parses dependencies from unordered lists" do
      markdown = """
      # Title

      ## Dependencies
      - First item
      - Second item
      - Third item
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert is_list(sections["dependencies"])
      assert sections["dependencies"] == ["First item", "Second item", "Third item"]
    end

    test "parses components into SpecComponent structs" do
      markdown = """
      # Title

      ## Components

      ### MyApp.Foo

      Handles business logic for foo operations.

      ### MyApp.Bar

      Manages schema for bar entities.
      """

      alias CodeMySpec.Documents.SpecComponent

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert [%SpecComponent{}, %SpecComponent{}] = sections["components"]
      assert Enum.any?(sections["components"], &(&1.module_name == "MyApp.Foo"))
      assert Enum.any?(sections["components"], &(&1.module_name == "MyApp.Bar"))

      foo = Enum.find(sections["components"], &(&1.module_name == "MyApp.Foo"))
      assert foo.description == "Handles business logic for foo operations."
    end

    test "handles code blocks within sections" do
      markdown = """
      # Title

      ## Public API

      ```elixir
      @spec create(attrs :: map()) :: {:ok, Entity.t()}
      ```
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections["public api"] =~ "@spec create"
    end
  end

  describe "parse/1 - edge cases" do
    test "handles markdown with only H1" do
      markdown = """
      # Title
      Some content after title.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections == %{}
    end

    test "handles empty markdown" do
      markdown = ""

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections == %{}
    end

    test "handles multiple paragraphs in a section" do
      markdown = """
      # Title

      ## Purpose

      First paragraph with content.

      Second paragraph with more content.

      Third paragraph.
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert sections["purpose"] =~ "First paragraph"
      assert sections["purpose"] =~ "Second paragraph"
      assert sections["purpose"] =~ "Third paragraph"
    end

    test "trims whitespace from section content" do
      markdown = """
      # Title

      ## Purpose


      Content with extra spacing.


      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)
      assert String.trim(sections["purpose"]) == "Content with extra spacing."
    end
  end

  describe "parse/1 - real-world spec format" do
    test "parses complete spec document with functions and delegates" do
      markdown = """
      # CodeMySpec.Components

      **Type**: context

      Coordinate component creation and management.

      ## Delegates

      - list_components/1: Components.ComponentRepository.list_components/1
      - get_component/2: Components.ComponentRepository.get_component/2

      ## Functions

      ### create_component/2

      Create a new component with validation.

      ```elixir
      @spec create_component(Scope.t(), map()) :: {:ok, Component.t()} | {:error, Changeset.t()}
      ```

      **Process**:
      1. Validate attributes
      2. Insert into database
      3. Return result

      **Test Assertions**:
      - creates component with valid attributes
      - returns error with invalid attributes

      ## Dependencies

      - CodeMySpec.Repo
      - CodeMySpec.Utils
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)

      # Delegates should be plain text
      assert is_binary(sections["delegates"])
      assert sections["delegates"] =~ "list_components/1"

      # Functions should be parsed
      assert [%Function{} = func] = sections["functions"]
      assert func.name == "create_component/2"
      assert func.spec =~ "@spec create_component"

      # Dependencies should be parsed as list
      assert is_list(sections["dependencies"])
      assert "CodeMySpec.Repo" in sections["dependencies"]
      assert "CodeMySpec.Utils" in sections["dependencies"]
    end

    test "parses schema spec with fields" do
      markdown = """
      # CodeMySpec.Components.Component

      **Type**: schema

      Represents a component entity in the system.

      ## Fields

      | Field | Type | Required | Description | Constraints |
      |-------|------|----------|-------------|-------------|
      | id | integer | Yes (auto) | Primary key | Auto-generated |
      | name | string | Yes | Component name | Min: 1, Max: 255 |
      | type | string | Yes | Component type | One of: logic, schema, repository |
      | parent_id | integer | No | Parent component | References components.id |
      """

      assert {:ok, sections} = MarkdownParser.parse(markdown)

      # Fields should be parsed
      assert fields = sections["fields"]
      assert length(fields) == 4
      assert Enum.all?(fields, &match?(%Field{}, &1))
      assert Enum.any?(fields, &(&1.field == "id"))
      assert Enum.any?(fields, &(&1.field == "name"))
      assert Enum.any?(fields, &(&1.field == "type"))
      assert Enum.any?(fields, &(&1.field == "parent_id"))
    end
  end
end
