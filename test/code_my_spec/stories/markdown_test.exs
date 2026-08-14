defmodule CodeMySpec.Stories.MarkdownTest do
  use ExUnit.Case, async: true
  doctest CodeMySpec.Stories.Markdown
  alias CodeMySpec.Stories.Markdown

  describe "validate_format/1" do
    test "validates valid markdown format with project header" do
      markdown = """
      # Project Name

      ## Story Title

      Story description here.

      **Acceptance Criteria**
      - Criterion 1
      - Criterion 2
      """

      assert {:ok, :valid} = Markdown.validate_format(markdown)
    end

    test "validates valid markdown format without project header" do
      markdown = """
      ## Story Title

      Story description here.

      **Acceptance Criteria**
      - Criterion 1
      - Criterion 2
      """

      assert {:ok, :valid} = Markdown.validate_format(markdown)
    end

    test "returns error for empty document" do
      assert {:error, :empty_document} = Markdown.validate_format("")
      assert {:error, :empty_document} = Markdown.validate_format("   \n  ")
    end

    test "returns error for missing story sections" do
      markdown = """
      # Project Name

      Some content without story sections.
      """

      assert {:error, :missing_sections} = Markdown.validate_format(markdown)
    end

    test "returns error for malformed headers" do
      markdown = """
      # Project Name

      ## 

      Story description here.
      """

      assert {:error, :malformed_headers} = Markdown.validate_format(markdown)
    end
  end

  describe "parse_markdown/1" do
    test "parses complete markdown document with single story" do
      markdown = """
      # My Project

      ## User Login

      As a user, I want to log in to access my account.

      **Acceptance Criteria**
      - User can enter email and password
      - System validates credentials
      - User is redirected to dashboard on success
      """

      expected = [
        %{
          title: "User Login",
          description: "As a user, I want to log in to access my account.",
          acceptance_criteria: [
            "User can enter email and password",
            "System validates credentials",
            "User is redirected to dashboard on success"
          ]
        }
      ]

      assert {:ok, stories} = Markdown.parse_markdown(markdown)
      assert stories == expected
    end

    test "parses markdown with multiple stories" do
      markdown = """
      # My Project

      ## User Registration

      User can create new account.

      **Acceptance Criteria**
      - Email validation required
      - Password strength requirements

      ## User Login

      User can access existing account.

      **Acceptance Criteria**
      - Valid credentials required
      """

      assert {:ok, stories} = Markdown.parse_markdown(markdown)
      assert length(stories) == 2
      assert Enum.any?(stories, &(&1.title == "User Registration"))
      assert Enum.any?(stories, &(&1.title == "User Login"))
    end

    test "parses story without acceptance criteria" do
      markdown = """
      # Project

      ## Simple Story

      Just a basic story description.
      """

      expected = [
        %{
          title: "Simple Story",
          description: "Just a basic story description.",
          acceptance_criteria: []
        }
      ]

      assert {:ok, stories} = Markdown.parse_markdown(markdown)
      assert stories == expected
    end

    test "parses stories without project header" do
      markdown = """
      ## User Registration

      User can create a new account with email and password.

      **Acceptance Criteria**
      - Email validation required
      - Password strength requirements

      ## User Login

      User can access existing account.

      **Acceptance Criteria**
      - Valid credentials required
      """

      assert {:ok, stories} = Markdown.parse_markdown(markdown)
      assert length(stories) == 2
      assert Enum.any?(stories, &(&1.title == "User Registration"))
      assert Enum.any?(stories, &(&1.title == "User Login"))
    end

    test "returns error for invalid format" do
      assert {:error, :empty_document} = Markdown.parse_markdown("")
    end
  end

  describe "format_stories/1" do
    test "formats single story to markdown" do
      stories = [
        %{
          title: "User Login",
          description: "User authentication functionality.",
          acceptance_criteria: ["Valid credentials", "Redirect on success"]
        }
      ]

      result = Markdown.format_stories(stories)

      assert String.contains?(result, "## User Login")
      assert String.contains?(result, "User authentication functionality.")
      assert String.contains?(result, "**Acceptance Criteria**")
      assert String.contains?(result, "- Valid credentials")
      assert String.contains?(result, "- Redirect on success")
    end

    test "formats multiple stories to markdown" do
      stories = [
        %{
          title: "Story One",
          description: "First story.",
          acceptance_criteria: ["Criterion 1"]
        },
        %{
          title: "Story Two",
          description: "Second story.",
          acceptance_criteria: ["Criterion 2"]
        }
      ]

      result = Markdown.format_stories(stories)

      assert String.contains?(result, "## Story One")
      assert String.contains?(result, "## Story Two")
      assert String.contains?(result, "First story.")
      assert String.contains?(result, "Second story.")
    end

    test "formats story without acceptance criteria" do
      stories = [
        %{
          title: "Simple Story",
          description: "Basic description.",
          acceptance_criteria: []
        }
      ]

      result = Markdown.format_stories(stories)

      assert String.contains?(result, "## Simple Story")
      assert String.contains?(result, "Basic description.")
      refute String.contains?(result, "**Acceptance Criteria**")
    end

    test "formats empty list to empty string" do
      assert Markdown.format_stories([]) == ""
    end
  end

  describe "integration tests" do
    test "round-trip parsing and formatting preserves data" do
      original_markdown = """
      # Test Project

      ## Feature A

      Description for feature A with multiple lines
      that span across several lines.

      **Acceptance Criteria**
      - First criterion
      - Second criterion
      - Third criterion

      ## Feature B

      Simple feature description.

      **Acceptance Criteria**
      - Single criterion
      """

      assert {:ok, stories} = Markdown.parse_markdown(original_markdown)
      formatted = Markdown.format_stories(stories, "Test Project")
      assert {:ok, reparsed_stories} = Markdown.parse_markdown(formatted)

      assert stories == reparsed_stories
    end

    test "handles complex multiline descriptions" do
      markdown = """
      # Complex Project

      ## Complex Story

      This is a story with a very detailed description
      that spans multiple paragraphs and contains
      various formatting elements.

      It might even have empty lines between paragraphs
      to separate different concepts or requirements.

      **Acceptance Criteria**
      - Handle multiline descriptions properly
      - Preserve paragraph structure
      - Maintain formatting integrity
      """

      assert {:ok, [story]} = Markdown.parse_markdown(markdown)
      assert String.contains?(story.description, "multiple paragraphs")
      assert String.contains?(story.description, "empty lines between paragraphs")
      assert length(story.acceptance_criteria) == 3
    end
  end
end
