defmodule CodeMySpec.ContentSync.HtmlProcessor do
  @moduledoc """
  Validates HTML content structure and checks for disallowed elements.

  Parses HTML using Floki to ensure well-formed markup and scans for JavaScript
  content that violates content guidelines (script tags, inline event handlers,
  javascript: protocol). Copies validated HTML to `processed_content` field on
  success. Returns validation errors with details for `parse_errors` field when
  HTML is malformed or contains disallowed JavaScript.

  ## Public API

      @spec process(raw_html :: String.t()) :: {:ok, ProcessorResult.t()}

  ## Example

      iex> HtmlProcessor.process("<p>Hello World</p>")
      {:ok, %ProcessorResult{
        raw_content: "<p>Hello World</p>",
        processed_content: "<p>Hello World</p>",
        parse_status: :success,
        parse_errors: nil
      }}

      iex> HtmlProcessor.process("<script>alert('xss')</script>")
      {:ok, %ProcessorResult{
        raw_content: "<script>alert('xss')</script>",
        processed_content: nil,
        parse_status: :error,
        parse_errors: %{
          error_type: "DisallowedContent",
          message: "HTML contains disallowed JavaScript content",
          violations: [...]
        }
      }}
  """

  alias CodeMySpec.ContentSync.ProcessorResult

  @event_handler_attributes [
    "onclick",
    "ondblclick",
    "onmousedown",
    "onmouseup",
    "onmouseover",
    "onmousemove",
    "onmouseout",
    "onmouseenter",
    "onmouseleave",
    "onkeydown",
    "onkeypress",
    "onkeyup",
    "onload",
    "onunload",
    "onabort",
    "onerror",
    "onresize",
    "onscroll",
    "onblur",
    "onchange",
    "onfocus",
    "onreset",
    "onselect",
    "onsubmit",
    "oninput",
    "oninvalid",
    "onsearch",
    "ondrag",
    "ondrop",
    "ondragstart",
    "ondragend",
    "ondragenter",
    "ondragleave",
    "ondragover",
    "onwheel",
    "oncopy",
    "oncut",
    "onpaste"
  ]

  @doc """
  Processes raw HTML content and validates it for structure and security.

  ## Parameters

    - `raw_html` - The HTML string to process

  ## Returns

    - `{:ok, ProcessorResult.t()}` - Always returns ok tuple with embedded
      errors in the ProcessorResult structure when validation fails

  ## Processing Steps

  1. Parse HTML using Floki
  2. Check for structure validation errors
  3. Scan for script tags
  4. Scan for inline event handlers (onclick, onload, etc.)
  5. Scan for javascript: protocol in href/src attributes
  6. Return success result if no violations, error result with details if violations found

  ## Examples

      iex> process("<p>Valid HTML</p>")
      {:ok, %ProcessorResult{parse_status: :success, ...}}

      iex> process("<script>alert('xss')</script>")
      {:ok, %ProcessorResult{parse_status: :error, ...}}
  """
  @spec process(raw_html :: String.t()) :: {:ok, ProcessorResult.t()}
  def process(raw_html) when is_binary(raw_html) do
    case Floki.parse_document(raw_html) do
      {:ok, document} ->
        violations = detect_javascript_violations(document)

        if Enum.empty?(violations) do
          {:ok, ProcessorResult.success(raw_html, raw_html)}
        else
          parse_errors = %{
            error_type: "DisallowedContent",
            message: "HTML contains disallowed JavaScript content",
            details: nil,
            violations: violations
          }

          {:ok, ProcessorResult.error(raw_html, parse_errors)}
        end

      {:error, reason} ->
        parse_errors = %{
          error_type: "Floki.ParseError",
          message: "Failed to parse HTML: #{inspect(reason)}",
          details: reason,
          line: nil
        }

        {:ok, ProcessorResult.error(raw_html, parse_errors)}
    end
  end

  # Detects all JavaScript-related violations in the parsed HTML document
  @spec detect_javascript_violations(Floki.html_tree()) :: [map()]
  defp detect_javascript_violations(document) do
    script_violations = detect_script_tags(document)
    event_handler_violations = detect_event_handlers(document)
    protocol_violations = detect_javascript_protocol(document)

    script_violations ++ event_handler_violations ++ protocol_violations
  end

  # Detects <script> tags in the document
  @spec detect_script_tags(Floki.html_tree()) :: [map()]
  defp detect_script_tags(document) do
    document
    |> Floki.find("script")
    |> Enum.map(fn _script_element ->
      %{
        type: "script_tag",
        element: "script"
      }
    end)
  end

  # Detects inline event handlers (onclick, onload, etc.) on any element
  @spec detect_event_handlers(Floki.html_tree()) :: [map()]
  defp detect_event_handlers(document) do
    document
    |> Floki.traverse_and_update([], &collect_event_handler_violations/2)
    |> elem(1)
  end

  defp collect_event_handler_violations({tag, attributes, _children} = element, acc)
       when is_list(attributes) do
    violations = Enum.flat_map(attributes, &event_handler_violation(&1, tag))
    {element, acc ++ violations}
  end

  defp collect_event_handler_violations(element, acc), do: {element, acc}

  defp event_handler_violation({attr_name, _attr_value}, tag) do
    if attr_name in @event_handler_attributes,
      do: [%{type: "event_handler", element: tag, attribute: attr_name}],
      else: []
  end

  # Detects javascript: protocol in href and src attributes
  @spec detect_javascript_protocol(Floki.html_tree()) :: [map()]
  defp detect_javascript_protocol(document) do
    Floki.traverse_and_update(document, [], &collect_js_protocol_violations/2)
    |> elem(1)
  end

  defp collect_js_protocol_violations({tag, attributes, _children} = element, acc)
       when is_list(attributes) do
    violations = Enum.flat_map(attributes, &js_protocol_violation(&1, tag))
    {element, acc ++ violations}
  end

  defp collect_js_protocol_violations(element, acc), do: {element, acc}

  defp js_protocol_violation({attr_name, attr_value}, tag) do
    if attr_name in ["href", "src"] and has_javascript_protocol?(attr_value),
      do: [%{type: "javascript_protocol", element: tag, attribute: attr_name}],
      else: []
  end

  # Checks if a string starts with "javascript:" (case-insensitive, with optional whitespace)
  @spec has_javascript_protocol?(String.t()) :: boolean()
  defp has_javascript_protocol?(value) when is_binary(value) do
    trimmed = String.trim(value)
    String.downcase(trimmed) |> String.starts_with?("javascript:")
  end

  defp has_javascript_protocol?(_), do: false
end
