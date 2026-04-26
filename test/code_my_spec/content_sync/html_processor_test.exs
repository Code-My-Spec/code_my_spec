defmodule CodeMySpec.ContentSync.HtmlProcessorTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ContentSync.HtmlProcessor

  # ============================================================================
  # Fixtures - Valid HTML Content
  # ============================================================================

  defp valid_minimal_html do
    """
    <p>Hello World</p>
    """
  end

  defp valid_complete_html do
    """
    <!DOCTYPE html>
    <html>
      <head>
        <title>Test Page</title>
        <meta name="description" content="A test page">
      </head>
      <body>
        <h1>Welcome</h1>
        <p>This is a test page with proper structure.</p>
        <ul>
          <li>Item 1</li>
          <li>Item 2</li>
        </ul>
      </body>
    </html>
    """
  end

  defp valid_html_with_attributes do
    """
    <div class="container" id="main">
      <p style="color: blue;">Styled paragraph</p>
      <a href="https://example.com" target="_blank" rel="noopener">External link</a>
      <img src="/images/test.jpg" alt="Test image" width="100" height="100">
    </div>
    """
  end

  defp valid_html_semantic_elements do
    """
    <article>
      <header>
        <h1>Article Title</h1>
        <time datetime="2025-01-15">January 15, 2025</time>
      </header>
      <section>
        <p>Article content goes here.</p>
      </section>
      <footer>
        <p>Author information</p>
      </footer>
    </article>
    """
  end

  defp valid_html_tables do
    """
    <table>
      <thead>
        <tr>
          <th>Header 1</th>
          <th>Header 2</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>Data 1</td>
          <td>Data 2</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp valid_html_forms do
    """
    <form action="/submit" method="post">
      <label for="name">Name:</label>
      <input type="text" id="name" name="name">
      <button type="submit">Submit</button>
    </form>
    """
  end

  defp valid_html_nested_structure do
    """
    <div>
      <section>
        <article>
          <header>
            <h1>Deeply Nested Content</h1>
          </header>
          <div>
            <p>Content inside multiple layers</p>
            <ul>
              <li>
                <span>Nested item</span>
              </li>
            </ul>
          </div>
        </article>
      </section>
    </div>
    """
  end

  # ============================================================================
  # Fixtures - HTML with Disallowed JavaScript
  # ============================================================================

  defp html_with_script_tag do
    """
    <div>
      <p>Safe content</p>
      <script>alert('xss');</script>
      <p>More content</p>
    </div>
    """
  end

  defp html_with_multiple_script_tags do
    """
    <div>
      <script src="/evil.js"></script>
      <p>Content</p>
      <script>console.log('tracking');</script>
    </div>
    """
  end

  defp html_with_inline_onclick do
    """
    <div>
      <button onclick="alert('clicked')">Click me</button>
    </div>
    """
  end

  defp html_with_inline_onload do
    """
    <body onload="trackPageView()">
      <p>Content</p>
    </body>
    """
  end

  defp html_with_inline_onmouseover do
    """
    <div onmouseover="showTooltip()">
      <p>Hover over me</p>
    </div>
    """
  end

  defp html_with_multiple_inline_handlers do
    """
    <div>
      <button onclick="handleClick()" onmouseover="handleHover()">Button</button>
      <input type="text" onchange="handleChange()" onfocus="handleFocus()">
    </div>
    """
  end

  defp html_with_javascript_protocol_href do
    """
    <a href="javascript:alert('xss')">Click me</a>
    """
  end

  defp html_with_javascript_protocol_src do
    """
    <img src="javascript:void(0)">
    """
  end

  defp html_with_mixed_javascript do
    """
    <div>
      <script>alert('script tag');</script>
      <button onclick="alert('onclick')">Button</button>
      <a href="javascript:void(0)">Link</a>
    </div>
    """
  end

  defp html_with_onsubmit do
    """
    <form onsubmit="return validateForm()">
      <input type="text" name="email">
    </form>
    """
  end

  defp html_with_onerror do
    """
    <img src="invalid.jpg" onerror="trackError()">
    """
  end

  # ============================================================================
  # Fixtures - Malformed HTML
  # ============================================================================

  defp html_with_unclosed_tags do
    """
    <div>
      <p>Paragraph without closing tag
      <span>Span without closing tag
    </div>
    """
  end

  defp html_with_mismatched_tags do
    """
    <div>
      <p>Content</span>
    </div>
    """
  end

  defp html_with_invalid_nesting do
    """
    <p>
      <div>Block element inside paragraph</div>
    </p>
    """
  end

  defp empty_html do
    ""
  end

  defp html_only_whitespace do
    """



    """
  end

  # ============================================================================
  # process/1 - Valid HTML Tests
  # ============================================================================

  describe "process/1 - valid minimal HTML" do
    test "successfully processes simple HTML paragraph" do
      assert {:ok, result} = HtmlProcessor.process(valid_minimal_html())
      assert result.parse_status == :success
      assert result.raw_content == valid_minimal_html()
      assert result.processed_content == valid_minimal_html()
      assert is_nil(result.parse_errors)
    end

    test "returns ProcessorResult struct with all required fields" do
      assert {:ok, result} = HtmlProcessor.process(valid_minimal_html())
      assert is_map(result)
      assert Map.has_key?(result, :raw_content)
      assert Map.has_key?(result, :processed_content)
      assert Map.has_key?(result, :parse_status)
      assert Map.has_key?(result, :parse_errors)
    end
  end

  describe "process/1 - valid complete HTML" do
    test "successfully processes complete HTML document" do
      assert {:ok, result} = HtmlProcessor.process(valid_complete_html())
      assert result.parse_status == :success
      assert result.raw_content == valid_complete_html()
      assert result.processed_content == valid_complete_html()
      assert is_nil(result.parse_errors)
    end

    test "preserves HTML structure exactly" do
      html = valid_complete_html()
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.processed_content == html
    end
  end

  describe "process/1 - HTML with attributes" do
    test "successfully processes HTML with valid attributes" do
      assert {:ok, result} = HtmlProcessor.process(valid_html_with_attributes())
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "class=\"container\"")
      assert String.contains?(result.processed_content, "href=\"https://example.com\"")
      assert String.contains?(result.processed_content, "src=\"/images/test.jpg\"")
    end

    test "allows safe inline styles" do
      html = ~s(<p style="color: blue;">Styled text</p>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "style=")
    end

    test "allows data attributes" do
      html = ~s(<div data-id="123" data-name="test">Content</div>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "data-")
    end
  end

  describe "process/1 - semantic HTML elements" do
    test "successfully processes semantic HTML5 elements" do
      assert {:ok, result} = HtmlProcessor.process(valid_html_semantic_elements())
      assert result.parse_status == :success
      assert String.contains?(result.raw_content, "<article>")
      assert String.contains?(result.raw_content, "<header>")
      assert String.contains?(result.raw_content, "<section>")
      assert String.contains?(result.raw_content, "<footer>")
    end

    test "allows time elements with datetime attributes" do
      html = ~s(<time datetime="2025-01-15">January 15, 2025</time>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end
  end

  describe "process/1 - HTML tables" do
    test "successfully processes table structures" do
      assert {:ok, result} = HtmlProcessor.process(valid_html_tables())
      assert result.parse_status == :success
      assert String.contains?(result.raw_content, "<table>")
      assert String.contains?(result.raw_content, "<thead>")
      assert String.contains?(result.raw_content, "<tbody>")
    end
  end

  describe "process/1 - HTML forms" do
    test "successfully processes form elements without JavaScript" do
      assert {:ok, result} = HtmlProcessor.process(valid_html_forms())
      assert result.parse_status == :success
      assert String.contains?(result.raw_content, "<form")
      assert String.contains?(result.raw_content, "<input")
      assert String.contains?(result.raw_content, "<button")
    end
  end

  describe "process/1 - nested structures" do
    test "successfully processes deeply nested HTML" do
      assert {:ok, result} = HtmlProcessor.process(valid_html_nested_structure())
      assert result.parse_status == :success
      assert result.processed_content == valid_html_nested_structure()
    end
  end

  # ============================================================================
  # process/1 - JavaScript Detection Tests
  # ============================================================================

  describe "process/1 - script tag detection" do
    test "returns error for HTML with script tag" do
      assert {:ok, result} = HtmlProcessor.process(html_with_script_tag())
      assert result.parse_status == :error
      assert result.raw_content == html_with_script_tag()
      assert is_nil(result.processed_content)
      assert not is_nil(result.parse_errors)
    end

    test "error includes violation details for script tag" do
      assert {:ok, result} = HtmlProcessor.process(html_with_script_tag())
      assert result.parse_errors.error_type == "DisallowedContent"
      assert result.parse_errors.message == "HTML contains disallowed JavaScript content"
      assert is_list(result.parse_errors.violations)
      assert result.parse_errors.violations != []
    end

    test "detects script tag violation type" do
      assert {:ok, result} = HtmlProcessor.process(html_with_script_tag())
      [violation | _] = result.parse_errors.violations
      assert violation.type == "script_tag"
      assert violation.element == "script"
    end

    test "detects multiple script tags" do
      assert {:ok, result} = HtmlProcessor.process(html_with_multiple_script_tags())
      assert result.parse_status == :error
      assert length(result.parse_errors.violations) >= 2
    end

    test "detects script tags with src attribute" do
      html = ~s(<script src="/external.js"></script>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
      [violation | _] = result.parse_errors.violations
      assert violation.type == "script_tag"
    end
  end

  describe "process/1 - inline event handler detection" do
    test "returns error for onclick attribute" do
      assert {:ok, result} = HtmlProcessor.process(html_with_inline_onclick())
      assert result.parse_status == :error
      assert result.raw_content == html_with_inline_onclick()
      assert is_nil(result.processed_content)
    end

    test "error includes violation details for onclick" do
      assert {:ok, result} = HtmlProcessor.process(html_with_inline_onclick())
      [violation | _] = result.parse_errors.violations
      assert violation.type == "event_handler"
      assert violation.element == "button"
      assert violation.attribute == "onclick"
    end

    test "detects onload attribute" do
      assert {:ok, result} = HtmlProcessor.process(html_with_inline_onload())
      assert result.parse_status == :error
      [violation | _] = result.parse_errors.violations
      assert violation.attribute == "onload"
    end

    test "detects onmouseover attribute" do
      assert {:ok, result} = HtmlProcessor.process(html_with_inline_onmouseover())
      assert result.parse_status == :error
      [violation | _] = result.parse_errors.violations
      assert violation.attribute == "onmouseover"
    end

    test "detects onsubmit attribute" do
      assert {:ok, result} = HtmlProcessor.process(html_with_onsubmit())
      assert result.parse_status == :error
      [violation | _] = result.parse_errors.violations
      assert violation.attribute == "onsubmit"
    end

    test "detects onerror attribute" do
      assert {:ok, result} = HtmlProcessor.process(html_with_onerror())
      assert result.parse_status == :error
      [violation | _] = result.parse_errors.violations
      assert violation.attribute == "onerror"
    end

    test "detects multiple inline event handlers" do
      assert {:ok, result} = HtmlProcessor.process(html_with_multiple_inline_handlers())
      assert result.parse_status == :error
      assert length(result.parse_errors.violations) >= 2
    end

    test "detects onchange attribute" do
      html = "<input type=\"text\" onchange=\"handleChange()\">"
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end

    test "detects onfocus attribute" do
      html = "<input type=\"text\" onfocus=\"handleFocus()\">"
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end

    test "detects onblur attribute" do
      html = "<input type=\"text\" onblur=\"handleBlur()\">"
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end
  end

  describe "process/1 - javascript: protocol detection" do
    test "returns error for javascript: in href" do
      assert {:ok, result} = HtmlProcessor.process(html_with_javascript_protocol_href())
      assert result.parse_status == :error
      assert result.raw_content == html_with_javascript_protocol_href()
      assert is_nil(result.processed_content)
    end

    test "error includes violation details for javascript: protocol" do
      assert {:ok, result} = HtmlProcessor.process(html_with_javascript_protocol_href())
      [violation | _] = result.parse_errors.violations
      assert violation.type == "javascript_protocol"
      assert violation.element == "a"
      assert violation.attribute == "href"
    end

    test "detects javascript: in src attribute" do
      assert {:ok, result} = HtmlProcessor.process(html_with_javascript_protocol_src())
      assert result.parse_status == :error
      [violation | _] = result.parse_errors.violations
      assert violation.type == "javascript_protocol"
      assert violation.attribute == "src"
    end

    test "detects javascript: with different casing" do
      html = "<a href=\"JavaScript:alert()\">Link</a>"
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end

    test "detects javascript: with whitespace" do
      html = "<a href=\"  javascript:alert()\">Link</a>"
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end
  end

  describe "process/1 - mixed JavaScript violations" do
    test "detects multiple types of violations" do
      assert {:ok, result} = HtmlProcessor.process(html_with_mixed_javascript())
      assert result.parse_status == :error
      assert length(result.parse_errors.violations) >= 3
    end

    test "reports all violation types found" do
      assert {:ok, result} = HtmlProcessor.process(html_with_mixed_javascript())
      violation_types = Enum.map(result.parse_errors.violations, & &1.type)
      assert "script_tag" in violation_types
      assert "event_handler" in violation_types
      assert "javascript_protocol" in violation_types
    end
  end

  # ============================================================================
  # process/1 - Malformed HTML Tests
  # ============================================================================

  describe "process/1 - malformed HTML" do
    test "handles unclosed tags gracefully" do
      # Floki is lenient and may parse this successfully
      assert {:ok, result} = HtmlProcessor.process(html_with_unclosed_tags())
      # Test that we get a result regardless of parse status
      assert result.raw_content == html_with_unclosed_tags()
      assert result.parse_status in [:success, :error]
    end

    test "handles mismatched tags" do
      # Floki is lenient and may parse this successfully
      assert {:ok, result} = HtmlProcessor.process(html_with_mismatched_tags())
      assert result.raw_content == html_with_mismatched_tags()
    end

    test "handles invalid nesting" do
      # Floki is lenient with invalid nesting
      assert {:ok, result} = HtmlProcessor.process(html_with_invalid_nesting())
      assert result.raw_content == html_with_invalid_nesting()
    end
  end

  describe "process/1 - empty and whitespace HTML" do
    test "successfully processes empty HTML" do
      assert {:ok, result} = HtmlProcessor.process(empty_html())
      assert result.parse_status == :success
      assert result.raw_content == empty_html()
      assert result.processed_content == empty_html()
    end

    test "successfully processes whitespace-only HTML" do
      assert {:ok, result} = HtmlProcessor.process(html_only_whitespace())
      assert result.parse_status == :success
      assert result.raw_content == html_only_whitespace()
    end
  end

  # ============================================================================
  # process/1 - Edge Cases
  # ============================================================================

  describe "process/1 - edge cases" do
    test "handles very long HTML content" do
      long_html = "<div>" <> String.duplicate("<p>Content paragraph.</p>", 1000) <> "</div>"
      assert {:ok, result} = HtmlProcessor.process(long_html)
      assert result.parse_status == :success
      assert String.length(result.processed_content) > 10_000
    end

    test "handles unicode characters in HTML" do
      html = ~s(<p>测试内容 rocket émojis</p>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
      assert String.contains?(result.processed_content, "测试内容")
      assert String.contains?(result.processed_content, "rocket")
    end

    test "handles HTML entities" do
      html = "<p>&lt;script&gt;alert('safe')&lt;/script&gt;</p>"
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
      assert String.contains?(result.raw_content, "&lt;")
      assert String.contains?(result.raw_content, "&gt;")
    end

    test "handles HTML comments" do
      html = """
      <div>
        <!-- This is a comment -->
        <p>Content</p>
        <!-- Another comment -->
      </div>
      """

      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "handles CDATA sections" do
      html = """
      <div>
        <![CDATA[
          Some CDATA content
        ]]>
      </div>
      """

      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.raw_content == html
    end

    test "handles self-closing tags" do
      html = """
      <div>
        <img src="/test.jpg" alt="test" />
        <br />
        <hr />
      </div>
      """

      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "handles very deeply nested HTML" do
      nested =
        Enum.reduce(1..50, "<p>Deep content</p>", fn _, acc ->
          "<div>#{acc}</div>"
        end)

      assert {:ok, result} = HtmlProcessor.process(nested)
      assert result.parse_status == :success
    end

    test "handles HTML with many attributes" do
      html = """
      <div
        id="test"
        class="container main active"
        data-id="123"
        data-name="test"
        data-value="abc"
        aria-label="test"
        aria-describedby="desc"
        role="main"
        title="Test div"
        style="color: blue;"
      >
        Content
      </div>
      """

      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "handles empty attributes" do
      html = ~s(<input type="text" disabled readonly required>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end
  end

  # ============================================================================
  # process/1 - Safe HTML Patterns
  # ============================================================================

  describe "process/1 - safe patterns that should pass" do
    test "allows safe anchor links" do
      html = ~s(<a href="https://example.com">Link</a>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "allows relative links" do
      html = ~s(<a href="/about">About</a>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "allows anchor links" do
      html = ~s(<a href="#section">Jump to section</a>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "allows mailto links" do
      html = ~s(<a href="mailto:test@example.com">Email</a>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "allows tel links" do
      html = ~s(<a href="tel:+1234567890">Call</a>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "allows image sources with valid protocols" do
      html = ~s(<img src="https://example.com/image.jpg" alt="test">)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "allows data URIs in images" do
      html = ~s(<img src="data:image/png;base64,iVBORw0KG..." alt="test">)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end
  end

  # ============================================================================
  # process/1 - Consistency Tests
  # ============================================================================

  describe "process/1 - consistency properties" do
    test "processing same HTML multiple times returns identical results" do
      html = valid_complete_html()
      {:ok, result1} = HtmlProcessor.process(html)
      {:ok, result2} = HtmlProcessor.process(html)
      {:ok, result3} = HtmlProcessor.process(html)

      assert result1 == result2
      assert result2 == result3
    end

    test "success results have consistent structure" do
      assert {:ok, result} = HtmlProcessor.process(valid_minimal_html())
      assert is_map(result)
      assert result.parse_status == :success
      assert is_binary(result.raw_content)
      assert is_binary(result.processed_content)
      assert is_nil(result.parse_errors)
    end

    test "error results have consistent structure" do
      assert {:ok, result} = HtmlProcessor.process(html_with_script_tag())
      assert is_map(result)
      assert result.parse_status == :error
      assert is_binary(result.raw_content)
      assert is_nil(result.processed_content)
      assert is_map(result.parse_errors)
      assert Map.has_key?(result.parse_errors, :error_type)
      assert Map.has_key?(result.parse_errors, :message)
      assert Map.has_key?(result.parse_errors, :violations)
    end

    test "violation structures are consistent" do
      assert {:ok, result} = HtmlProcessor.process(html_with_script_tag())
      [violation | _] = result.parse_errors.violations

      assert is_map(violation)
      assert Map.has_key?(violation, :type)
      assert Map.has_key?(violation, :element)
    end
  end

  # ============================================================================
  # process/1 - Security Tests
  # ============================================================================

  describe "process/1 - security considerations" do
    test "blocks potential XSS via script tags" do
      html = ~s(<div><script>document.cookie</script></div>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end

    test "blocks potential XSS via onclick handlers" do
      html = ~s(<div onclick="document.location='http://evil.com'">Click</div>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end

    test "blocks potential XSS via javascript: protocol" do
      html = ~s(<a href="javascript:document.location='http://evil.com'">Link</a>)
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
    end

    test "does not execute JavaScript during validation" do
      # This test ensures that the validation process itself doesn't execute JS
      html = "<script>process.exit(1)</script>"
      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :error
      # If we get here, the JavaScript wasn't executed
    end

    test "safely handles HTML with special characters that could break parsing" do
      html = ~s(<p>Content with "quotes" and 'apostrophes' and <brackets></p>)
      assert {:ok, _result} = HtmlProcessor.process(html)
    end
  end

  # ============================================================================
  # process/1 - Real World HTML Examples
  # ============================================================================

  describe "process/1 - real world examples" do
    test "processes typical blog post HTML" do
      html = """
      <article>
        <header>
          <h1>Blog Post Title</h1>
          <p class="meta">Posted on January 15, 2025 by Author Name</p>
        </header>
        <div class="content">
          <p>First paragraph of the blog post.</p>
          <p>Second paragraph with <strong>bold text</strong> and <em>italic text</em>.</p>
          <blockquote>
            <p>A quoted passage from another source.</p>
          </blockquote>
          <ul>
            <li>List item one</li>
            <li>List item two</li>
          </ul>
        </div>
      </article>
      """

      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "processes typical landing page HTML" do
      html = """
      <section class="hero">
        <h1>Welcome to Our Product</h1>
        <p>The best solution for your needs</p>
        <a href="/signup" class="cta-button">Get Started</a>
      </section>
      <section class="features">
        <div class="feature">
          <h2>Feature One</h2>
          <p>Description of feature one</p>
        </div>
        <div class="feature">
          <h2>Feature Two</h2>
          <p>Description of feature two</p>
        </div>
      </section>
      """

      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end

    test "processes HTML with embedded media" do
      html = """
      <div class="media-content">
        <img src="/images/photo.jpg" alt="A photograph">
        <video poster="/images/poster.jpg">
          <source src="/videos/video.mp4" type="video/mp4">
        </video>
        <audio controls>
          <source src="/audio/track.mp3" type="audio/mpeg">
        </audio>
      </div>
      """

      assert {:ok, result} = HtmlProcessor.process(html)
      assert result.parse_status == :success
    end
  end
end
