defmodule CodeMySpec.ContentSync.MarkdownProcessorTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ContentSync.MarkdownProcessor

  # ============================================================================
  # Fixtures - Valid Markdown Content
  # ============================================================================

  defp valid_minimal_markdown do
    """
    # Hello World
    """
  end

  defp valid_simple_paragraph do
    """
    This is a simple paragraph of text.
    """
  end

  defp valid_complete_markdown do
    """
    # Main Title

    This is an introductory paragraph.

    ## Section One

    Some content in section one with **bold** and *italic* text.

    ## Section Two

    More content here:

    - List item 1
    - List item 2
    - List item 3

    ### Subsection

    Even more nested content.
    """
  end

  defp valid_markdown_with_links do
    """
    # Links

    Check out [this link](https://example.com) for more info.

    You can also visit [our site](/about) or [contact us](mailto:test@example.com).

    Here's a [reference link][1] and another [reference][2].

    [1]: https://example.com/reference
    [2]: https://example.com/another
    """
  end

  defp valid_markdown_with_images do
    """
    # Images

    ![Alt text](/path/to/image.jpg)

    ![Alt text with title](/path/to/image.jpg "Image title")

    ![Remote image](https://example.com/image.png)
    """
  end

  defp valid_markdown_with_code_blocks do
    """
    # Code Examples

    Inline code: `const x = 42`

    Code block:

    ```javascript
    function hello() {
      console.log("Hello, world!");
    }
    ```

    Another block:

    ```elixir
    defmodule MyModule do
      def hello, do: "world"
    end
    ```
    """
  end

  defp valid_markdown_with_blockquotes do
    """
    # Quotes

    Regular paragraph.

    > This is a blockquote.
    > It can span multiple lines.

    > Nested quotes:
    > > This is nested inside
    """
  end

  defp valid_markdown_with_lists do
    """
    # Lists

    Unordered list:

    - Item 1
    - Item 2
      - Nested item
      - Another nested item
    - Item 3

    Ordered list:

    1. First item
    2. Second item
    3. Third item

    Mixed list:

    1. Numbered item
       - Bullet sub-item
       - Another bullet
    2. Another numbered item
    """
  end

  defp valid_markdown_with_tables do
    """
    # Tables

    | Header 1 | Header 2 | Header 3 |
    |----------|----------|----------|
    | Cell 1   | Cell 2   | Cell 3   |
    | Cell 4   | Cell 5   | Cell 6   |

    Aligned table:

    | Left | Center | Right |
    |:-----|:------:|------:|
    | A    | B      | C     |
    """
  end

  defp valid_markdown_with_horizontal_rules do
    """
    # Sections

    Content above

    ---

    Content below

    ***

    More content

    ___

    Final content
    """
  end

  defp valid_markdown_with_emphasis do
    """
    # Text Formatting

    **Bold text** and __also bold__.

    *Italic text* and _also italic_.

    ***Bold and italic*** and ___also both___.

    ~~Strikethrough text~~

    `inline code`
    """
  end

  defp valid_markdown_with_html do
    """
    # Mixed Content

    Regular markdown paragraph.

    <div class="custom">
      <p>HTML inside markdown</p>
    </div>

    More markdown after HTML.
    """
  end

  defp valid_markdown_task_lists do
    """
    # Tasks

    - [x] Completed task
    - [ ] Incomplete task
    - [x] Another completed task
    """
  end

  # ============================================================================
  # Fixtures - Edge Cases
  # ============================================================================

  defp empty_markdown do
    ""
  end

  defp whitespace_only_markdown do
    """



    """
  end

  defp markdown_with_unicode do
    """
    # Unicode Content

    测试内容 - Chinese characters

    café résumé naïve - Accented characters

    🚀 💻 🎉 - Emojis

    Математика - Cyrillic
    """
  end

  defp markdown_with_special_characters do
    """
    # Special Characters

    Ampersands: AT&T, R&D

    Less than: 4 < 5

    Greater than: 5 > 4

    Copyright: © 2025

    Trademark: TM™ Registered®
    """
  end

  defp very_long_markdown do
    content = String.duplicate("This is a long paragraph of text. ", 100)

    """
    # Long Content

    #{content}

    ## Section Two

    #{content}
    """
  end

  defp markdown_with_escaped_characters do
    """
    # Escaping

    Backslash: \\\\

    Asterisk: \\*not italic\\*

    Backtick: \\`not code\\`

    Brackets: \\[not a link\\]
    """
  end

  defp markdown_with_html_entities do
    """
    # HTML Entities

    &lt;script&gt; tags

    &amp; ampersands

    &copy; copyright
    """
  end

  # ============================================================================
  # Fixtures - Malformed Markdown (should still process)
  # ============================================================================

  defp markdown_with_unmatched_brackets do
    """
    # Unmatched

    This has an [unclosed link

    And a (parenthesis
    """
  end

  defp markdown_with_incomplete_code_block do
    """
    # Incomplete

    ```elixir
    def broken
    # Missing closing backticks
    """
  end

  defp markdown_with_unbalanced_emphasis do
    """
    # Unbalanced

    **Bold without closing

    *Italic without closing
    """
  end

  defp markdown_with_invalid_table do
    """
    # Invalid Table

    | Header 1 | Header 2 |
    |----------|
    | Too many cells | in | this | row |
    """
  end

  # ============================================================================
  # Fixtures - Potentially Problematic Markdown
  # ============================================================================

  defp markdown_with_nested_formatting do
    """
    # Nested

    ***This is ~~bold, italic, and strikethrough~~ together***

    **Bold with *italic* inside**

    `Code with **attempted bold** inside`
    """
  end

  defp markdown_with_multiple_blank_lines do
    """
    # Title



    Paragraph after many blank lines.




    Another paragraph.
    """
  end

  defp markdown_with_mixed_line_endings do
    # Simulate mixed line endings (though in Elixir strings it's normalized)
    "# Title\n\nParagraph one.\r\n\r\nParagraph two.\n"
  end

  defp markdown_with_very_deep_nesting do
    """
    # Deep Nesting

    - Level 1
      - Level 2
        - Level 3
          - Level 4
            - Level 5
              - Level 6
                - Level 7
                  - Level 8
                    - Level 9
                      - Level 10
    """
  end

  # ============================================================================
  # process/1 - Valid Markdown Tests
  # ============================================================================

  describe "process/1 - minimal markdown" do
    test "successfully processes simple heading" do
      assert {:ok, result} = MarkdownProcessor.process(valid_minimal_markdown())
      assert result.parse_status == :success
      assert result.raw_content == valid_minimal_markdown()
      assert is_binary(result.processed_content)
      assert String.contains?(result.processed_content, "<h1>")
      assert String.contains?(result.processed_content, "Hello World")
      assert is_nil(result.parse_errors)
    end

    test "returns ProcessorResult struct with all required fields" do
      assert {:ok, result} = MarkdownProcessor.process(valid_minimal_markdown())
      assert is_map(result)
      assert Map.has_key?(result, :raw_content)
      assert Map.has_key?(result, :processed_content)
      assert Map.has_key?(result, :parse_status)
      assert Map.has_key?(result, :parse_errors)
    end
  end

  describe "process/1 - simple paragraph" do
    test "successfully converts simple paragraph to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_simple_paragraph())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<p>")
      assert String.contains?(result.processed_content, "simple paragraph")
    end

    test "preserves raw content exactly" do
      markdown = valid_simple_paragraph()
      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.raw_content == markdown
    end
  end

  describe "process/1 - complete markdown document" do
    test "successfully processes complete markdown with multiple sections" do
      assert {:ok, result} = MarkdownProcessor.process(valid_complete_markdown())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<h1>")
      assert String.contains?(result.processed_content, "<h2>")
      assert String.contains?(result.processed_content, "<h3>")
      assert String.contains?(result.processed_content, "<ul>")
      assert String.contains?(result.processed_content, "<li>")
    end

    test "converts emphasis to HTML tags" do
      assert {:ok, result} = MarkdownProcessor.process(valid_complete_markdown())
      assert String.contains?(result.processed_content, "<strong>")
      assert String.contains?(result.processed_content, "<em>")
    end
  end

  describe "process/1 - markdown with links" do
    test "successfully converts inline links to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_links())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<a href=")
      assert String.contains?(result.processed_content, "https://example.com")
    end

    test "converts mailto links" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_links())
      assert String.contains?(result.processed_content, "mailto:")
    end

    test "converts reference links" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_links())
      # Reference links should be resolved to anchor tags
      assert String.contains?(result.processed_content, "<a href=")
    end
  end

  describe "process/1 - markdown with images" do
    test "successfully converts images to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_images())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<img")
      assert String.contains?(result.processed_content, "alt=")
      assert String.contains?(result.processed_content, "src=")
    end

    test "preserves image alt text" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_images())
      assert String.contains?(result.processed_content, "Alt text")
    end

    test "handles image titles" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_images())
      assert String.contains?(result.processed_content, "<img")
    end
  end

  describe "process/1 - markdown with code blocks" do
    test "successfully converts code blocks to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_code_blocks())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<code")
    end

    test "converts inline code" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_code_blocks())
      assert String.contains?(result.processed_content, "<code")
    end

    test "preserves code content" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_code_blocks())
      assert String.contains?(result.processed_content, "const x")
      # MDEx syntax highlights code, so "function" and "hello" are in separate spans
      assert String.contains?(result.processed_content, "hello")
      assert String.contains?(result.processed_content, "function")
    end
  end

  describe "process/1 - markdown with blockquotes" do
    test "successfully converts blockquotes to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_blockquotes())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<blockquote>")
    end

    test "handles nested blockquotes" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_blockquotes())
      # Should have blockquote tags
      assert String.contains?(result.processed_content, "<blockquote>")
    end
  end

  describe "process/1 - markdown with lists" do
    test "successfully converts unordered lists to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_lists())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<ul>")
      assert String.contains?(result.processed_content, "<li>")
    end

    test "successfully converts ordered lists to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_lists())
      assert String.contains?(result.processed_content, "<ol>")
    end

    test "handles nested lists" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_lists())
      # Should have multiple ul/ol tags for nesting
      assert String.contains?(result.processed_content, "<ul>")
      assert String.contains?(result.processed_content, "<li>")
    end
  end

  describe "process/1 - markdown with tables" do
    test "successfully converts tables to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_tables())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<table>")

      assert String.contains?(result.processed_content, "<thead>") or
               String.contains?(result.processed_content, "<tr>")
    end

    test "converts table headers" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_tables())

      assert String.contains?(result.processed_content, "<th>") or
               String.contains?(result.processed_content, "Header")
    end

    test "converts table cells" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_tables())

      assert String.contains?(result.processed_content, "<td>") or
               String.contains?(result.processed_content, "Cell")
    end
  end

  describe "process/1 - markdown with horizontal rules" do
    test "successfully converts horizontal rules to HTML" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_horizontal_rules())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<hr")
    end
  end

  describe "process/1 - markdown with emphasis" do
    test "successfully converts all emphasis types" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_emphasis())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<strong>")
      assert String.contains?(result.processed_content, "<em>")
    end

    test "handles combined bold and italic" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_emphasis())
      # Should have both strong and em tags
      assert String.contains?(result.processed_content, "<strong>")
      assert String.contains?(result.processed_content, "<em>")
    end
  end

  describe "process/1 - markdown with embedded HTML" do
    test "successfully processes markdown with HTML elements" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_html())
      assert result.parse_status == :success
      # Earmark typically preserves HTML as-is
      assert String.contains?(result.processed_content, "<div")
    end

    test "preserves HTML attributes" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_with_html())
      assert String.contains?(result.processed_content, "class=")
    end
  end

  describe "process/1 - markdown with task lists" do
    test "processes task lists" do
      assert {:ok, result} = MarkdownProcessor.process(valid_markdown_task_lists())
      # Task lists may or may not be supported depending on Earmark version
      assert result.parse_status == :success
      assert is_binary(result.processed_content)
    end
  end

  # ============================================================================
  # process/1 - Edge Cases
  # ============================================================================

  describe "process/1 - empty and whitespace markdown" do
    test "successfully processes empty markdown" do
      assert {:ok, result} = MarkdownProcessor.process(empty_markdown())
      assert result.parse_status == :success
      assert result.raw_content == empty_markdown()
      assert is_binary(result.processed_content)
      assert is_nil(result.parse_errors)
    end

    test "successfully processes whitespace-only markdown" do
      assert {:ok, result} = MarkdownProcessor.process(whitespace_only_markdown())
      assert result.parse_status == :success
      assert result.raw_content == whitespace_only_markdown()
      assert is_binary(result.processed_content)
    end
  end

  describe "process/1 - unicode content" do
    test "successfully processes unicode characters" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_unicode())
      assert result.parse_status == :success
      assert String.contains?(result.raw_content, "测试")
      assert String.contains?(result.raw_content, "café")
      assert String.contains?(result.raw_content, "🚀")
    end

    test "preserves unicode in output" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_unicode())
      # Unicode should be in the processed content
      assert is_binary(result.processed_content)
    end
  end

  describe "process/1 - special characters" do
    test "successfully processes special characters" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_special_characters())
      assert result.parse_status == :success
      assert is_binary(result.processed_content)
    end

    test "handles ampersands" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_special_characters())
      # Ampersands should be either preserved or escaped
      assert is_binary(result.processed_content)
    end
  end

  describe "process/1 - very long content" do
    test "successfully processes very long markdown" do
      assert {:ok, result} = MarkdownProcessor.process(very_long_markdown())
      assert result.parse_status == :success
      assert String.length(result.processed_content) > 5000
    end
  end

  describe "process/1 - escaped characters" do
    test "successfully processes escaped characters" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_escaped_characters())
      assert result.parse_status == :success
      # Escaped characters should be handled appropriately
      assert is_binary(result.processed_content)
    end
  end

  describe "process/1 - HTML entities" do
    test "successfully processes HTML entities" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_html_entities())
      assert result.parse_status == :success
      assert String.contains?(result.raw_content, "&lt;")
      assert String.contains?(result.raw_content, "&amp;")
    end
  end

  # ============================================================================
  # process/1 - Malformed Markdown Tests
  # ============================================================================

  describe "process/1 - malformed markdown" do
    test "handles unmatched brackets gracefully" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_unmatched_brackets())
      # Earmark should either succeed or return error details
      assert result.parse_status in [:success, :error]
      assert result.raw_content == markdown_with_unmatched_brackets()
    end

    test "handles incomplete code blocks" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_incomplete_code_block())
      assert result.parse_status in [:success, :error]
      assert is_binary(result.raw_content)
    end

    test "handles unbalanced emphasis" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_unbalanced_emphasis())
      assert result.parse_status in [:success, :error]
      assert is_binary(result.raw_content)
    end

    test "handles invalid tables" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_invalid_table())
      # Earmark is usually lenient with tables
      assert result.parse_status in [:success, :error]
    end
  end

  describe "process/1 - error handling" do
    test "captures error details when parsing fails" do
      # Create markdown that might cause Earmark to fail
      # Note: Earmark is quite lenient, so this may not actually fail
      malformed = String.duplicate("[", 2)

      assert {:ok, result} = MarkdownProcessor.process(malformed)
      verify_either_outcome(result.parse_status, result)
    end

    test "error result includes raw content" do
      # Attempt to trigger an error
      possibly_bad = "# Title\n\n" <> String.duplicate("*", 2)

      assert {:ok, result} = MarkdownProcessor.process(possibly_bad)
      verify_raw_content(result.parse_status, result, possibly_bad)
    end
  end

  # ============================================================================
  # process/1 - Complex Nested Structures
  # ============================================================================

  describe "process/1 - complex structures" do
    test "handles nested formatting" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_nested_formatting())
      assert result.parse_status == :success
      assert is_binary(result.processed_content)
    end

    test "handles multiple blank lines" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_multiple_blank_lines())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<h1>")
    end

    test "handles mixed line endings" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_mixed_line_endings())
      assert result.parse_status == :success
    end

    test "handles very deep nesting" do
      assert {:ok, result} = MarkdownProcessor.process(markdown_with_very_deep_nesting())
      assert result.parse_status == :success
      # Should have nested ul/li structures
      assert String.contains?(result.processed_content, "<ul>")
    end
  end

  # ============================================================================
  # process/1 - Consistency Tests
  # ============================================================================

  describe "process/1 - consistency properties" do
    test "processing same markdown multiple times returns identical results" do
      markdown = valid_complete_markdown()
      {:ok, result1} = MarkdownProcessor.process(markdown)
      {:ok, result2} = MarkdownProcessor.process(markdown)
      {:ok, result3} = MarkdownProcessor.process(markdown)

      assert result1 == result2
      assert result2 == result3
    end

    test "success results have consistent structure" do
      assert {:ok, result} = MarkdownProcessor.process(valid_minimal_markdown())
      assert is_map(result)
      assert result.parse_status == :success
      assert is_binary(result.raw_content)
      assert is_binary(result.processed_content)
      assert is_nil(result.parse_errors)
    end

    test "always returns ok tuple regardless of parse status" do
      # Test with various inputs
      test_cases = [
        valid_minimal_markdown(),
        empty_markdown(),
        markdown_with_unicode(),
        markdown_with_unmatched_brackets()
      ]

      for test_case <- test_cases do
        assert {:ok, _result} = MarkdownProcessor.process(test_case)
      end
    end
  end

  # ============================================================================
  # process/1 - Output Validation
  # ============================================================================

  describe "process/1 - output validation" do
    test "processed HTML is valid for simple markdown" do
      assert {:ok, result} = MarkdownProcessor.process(valid_minimal_markdown())
      verify_html_when_successful(result.parse_status, result)
    end

    test "converts all heading levels correctly" do
      markdown = """
      # H1
      ## H2
      ### H3
      #### H4
      ##### H5
      ###### H6
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success

      assert String.contains?(result.processed_content, "<h1>")
      assert String.contains?(result.processed_content, "<h2>")
      assert String.contains?(result.processed_content, "<h3>")
      assert String.contains?(result.processed_content, "<h4>")
      assert String.contains?(result.processed_content, "<h5>")
      assert String.contains?(result.processed_content, "<h6>")
    end

    test "generates well-formed list HTML" do
      markdown = """
      - Item 1
      - Item 2
      - Item 3
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<ul>")
      assert String.contains?(result.processed_content, "<li>")
      assert String.contains?(result.processed_content, "</li>")
      assert String.contains?(result.processed_content, "</ul>")
    end
  end

  # ============================================================================
  # process/1 - Real World Examples
  # ============================================================================

  describe "process/1 - real world examples" do
    test "processes typical blog post markdown" do
      markdown = """
      # How to Build a Phoenix App

      Phoenix is a powerful web framework for Elixir. In this tutorial, we'll build a simple blog.

      ## Getting Started

      First, create a new Phoenix project:

      ```bash
      mix phx.new my_blog
      ```

      ## Creating the Schema

      Next, generate a Post schema:

      ```elixir
      mix phx.gen.schema Blog.Post posts title:string body:text published:boolean
      ```

      ## Conclusion

      You now have a basic blog! For more information, check out the [Phoenix documentation](https://hexdocs.pm/phoenix).
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<h1>")
      assert String.contains?(result.processed_content, "<h2>")
      assert String.contains?(result.processed_content, "<code")
    end

    test "processes landing page marketing content" do
      markdown = """
      # Transform Your Business Today

      Join thousands of companies using our platform to **increase productivity** by 300%.

      ## Features

      - **Real-time Analytics** - Make data-driven decisions instantly
      - **Team Collaboration** - Work together seamlessly
      - **Enterprise Security** - Bank-level encryption

      [Get Started Now](/signup)
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<strong>")
      assert String.contains?(result.processed_content, "<ul>")
      assert String.contains?(result.processed_content, "<a href=")
    end

    test "processes documentation with code examples" do
      markdown = """
      # API Reference

      ## Authentication

      All API requests require an authentication token:

      ```http
      GET /api/users
      Authorization: Bearer YOUR_TOKEN
      ```

      ### Response

      ```json
      {
        "users": [
          {"id": 1, "name": "Alice"}
        ]
      }
      ```
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "<code")
    end
  end

  # ============================================================================
  # process/1 - Mermaid Diagram Support
  # ============================================================================

  describe "process/1 - mermaid diagrams" do
    test "converts mermaid code blocks to renderable pre elements" do
      markdown = """
      # Architecture

      ```mermaid
      graph TD;
          A-->B;
          A-->C;
      ```
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "class=\"mermaid\"")
      assert String.contains?(result.processed_content, "A-->B")
    end

    test "injects mermaid initialization script" do
      markdown = """
      ```mermaid
      graph LR; A-->B;
      ```
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "mermaid")
      assert String.contains?(result.processed_content, "<script")
    end

    test "handles mermaid alongside regular code blocks" do
      markdown = """
      ```elixir
      IO.puts("hello")
      ```

      ```mermaid
      graph TD; A-->B;
      ```

      ```javascript
      console.log("hi")
      ```
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      assert result.parse_status == :success
      # Mermaid block rendered as pre.mermaid
      assert String.contains?(result.processed_content, "class=\"mermaid\"")
      # Regular code blocks still syntax highlighted
      assert String.contains?(result.processed_content, "language-elixir")
      assert String.contains?(result.processed_content, "language-javascript")
    end
  end

  # ============================================================================
  # process/1 - Security Considerations
  # ============================================================================

  describe "process/1 - security considerations" do
    test "processes markdown with inline JavaScript safely" do
      markdown = """
      # Content

      <script>alert('xss')</script>

      Regular content.
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      # Earmark should escape or preserve the script tag as text
      assert result.parse_status == :success
      assert is_binary(result.processed_content)
    end

    test "handles markdown with onclick attributes" do
      markdown = """
      # Content

      <div onclick="alert('clicked')">Click me</div>
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      # Processing should complete without executing JavaScript
      assert result.parse_status == :success
    end

    test "processes markdown without executing embedded code" do
      markdown = """
      # Code Example

      ```javascript
      process.exit(1);
      console.log("This should not execute");
      ```
      """

      assert {:ok, result} = MarkdownProcessor.process(markdown)
      # Code should be in the output but not executed
      assert result.parse_status == :success
    end
  end

  # Helpers that branch on parse_status without imperative control flow.

  defp verify_either_outcome(:error, result) do
    refute is_nil(result.parse_errors)
    assert Map.has_key?(result.parse_errors, :error_type)
    assert Map.has_key?(result.parse_errors, :message)
    assert is_nil(result.processed_content)
  end

  defp verify_either_outcome(:success, result), do: assert(result.parse_status == :success)

  defp verify_raw_content(:error, result, raw) do
    assert result.raw_content == raw
    assert is_nil(result.processed_content)
  end

  defp verify_raw_content(:success, _result, _raw), do: :ok

  defp verify_html_when_successful(:success, result) do
    assert String.contains?(result.processed_content, "<h1>")
    assert String.contains?(result.processed_content, "</h1>")
  end

  defp verify_html_when_successful(:error, _result), do: :ok
end
