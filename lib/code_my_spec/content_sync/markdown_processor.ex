defmodule CodeMySpec.ContentSync.MarkdownProcessor do
  @moduledoc """
  Converts markdown content to HTML using the Earmark library.

  Populates the `processed_content` field with the rendered HTML output. Catches
  parsing errors and returns error tuples with detailed information for the
  `parse_errors` field, ensuring malformed markdown is gracefully handled within
  the content sync pipeline.

  ## Public API

      @spec process(raw_markdown :: String.t()) :: {:ok, ProcessorResult.t()}

  ## Example

      iex> MarkdownProcessor.process("# Hello World")
      {:ok, %ProcessorResult{
        raw_content: "# Hello World",
        processed_content: "<h1>Hello World</h1>",
        parse_status: :success,
        parse_errors: nil
      }}

      iex> MarkdownProcessor.process(invalid_markdown)
      {:ok, %ProcessorResult{
        raw_content: invalid_markdown,
        processed_content: nil,
        parse_status: :error,
        parse_errors: %{
          error_type: "Earmark.Error",
          message: "Parsing failed",
          line: 5,
          context: ...
        }
      }}
  """

  alias CodeMySpec.ContentSync.ProcessorResult

  @doc """
  Processes raw markdown content and converts it to HTML.

  ## Parameters

    - `raw_markdown` - The markdown string to process

  ## Returns

    - `{:ok, ProcessorResult.t()}` - Always returns ok tuple with embedded
      errors in the ProcessorResult structure when parsing fails

  ## Processing Steps

  1. Attempt to convert markdown to HTML using Earmark.as_html/1
  2. On success: return result with processed_content as HTML string
  3. On error: catch parsing exceptions and return result with parse_errors map
  4. Always return {:ok, result} tuple (errors captured in result, not as error tuples)

  ## Examples

      iex> process("# Title")
      {:ok, %ProcessorResult{parse_status: :success, ...}}

      iex> process(malformed_markdown)
      {:ok, %ProcessorResult{parse_status: :error, ...}}
  """
  @spec process(raw_markdown :: String.t()) :: {:ok, ProcessorResult.t()}
  def process(raw_markdown) when is_binary(raw_markdown) do
    case Earmark.as_html(raw_markdown) do
      {:ok, html_iodata, _warnings} ->
        html_string = IO.iodata_to_binary(html_iodata)
        {:ok, ProcessorResult.success(raw_markdown, html_string)}

      {:error, _html_iodata, error_messages} ->
        parse_errors = build_error_map(error_messages)
        {:ok, ProcessorResult.error(raw_markdown, parse_errors)}
    end
  rescue
    exception ->
      parse_errors = %{
        error_type: exception.__struct__ |> to_string() |> String.replace("Elixir.", ""),
        message: Exception.message(exception),
        details: inspect(exception),
        line: nil,
        context: nil
      }

      {:ok, ProcessorResult.error(raw_markdown, parse_errors)}
  end

  # Builds error map from Earmark error messages
  @spec build_error_map(list()) :: map()
  defp build_error_map(error_messages) when is_list(error_messages) do
    first_error = List.first(error_messages)

    %{
      error_type: "Earmark.ParseError",
      message: extract_error_message(first_error),
      details: Enum.map(error_messages, &serialize_error_tuple/1),
      line: extract_line_number(first_error),
      context: extract_context(first_error)
    }
  end

  defp serialize_error_tuple({severity, line, message}) do
    %{severity: severity, line: line, message: message}
  end

  defp serialize_error_tuple(other), do: %{message: inspect(other)}

  # Extracts error message from Earmark error tuple
  @spec extract_error_message(tuple() | any()) :: String.t()
  defp extract_error_message({_severity, line_number, message}) when is_binary(message) do
    "Line #{line_number}: #{message}"
  end

  defp extract_error_message({_severity, _line_number, message}) do
    inspect(message)
  end

  defp extract_error_message(error) do
    inspect(error)
  end

  # Extracts line number from Earmark error tuple
  @spec extract_line_number(tuple() | any()) :: integer() | nil
  defp extract_line_number({_severity, line_number, _message}) when is_integer(line_number) do
    line_number
  end

  defp extract_line_number(_), do: nil

  # Extracts context from Earmark error tuple
  @spec extract_context(tuple() | any()) :: any()
  defp extract_context({severity, line_number, message}) do
    %{
      severity: severity,
      line: line_number,
      message: message
    }
  end

  defp extract_context(_), do: nil
end
