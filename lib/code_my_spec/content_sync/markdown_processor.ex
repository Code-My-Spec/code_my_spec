defmodule CodeMySpec.ContentSync.MarkdownProcessor do
  @moduledoc """
  Converts markdown content to HTML using MDEx (comrak) with the MDExMermaid plugin.

  Populates the `processed_content` field with the rendered HTML output. Mermaid
  code blocks are automatically converted to client-renderable `<pre class="mermaid">`
  elements with an injected initialization script. Catches parsing errors and returns
  error tuples with detailed information for the `parse_errors` field.

  ## Public API

      @spec process(raw_markdown :: String.t()) :: {:ok, ProcessorResult.t()}

  ## Example

      iex> MarkdownProcessor.process("# Hello World")
      {:ok, %ProcessorResult{
        raw_content: "# Hello World",
        processed_content: "<h1>Hello World</h1>\\n",
        parse_status: :success,
        parse_errors: nil
      }}
  """

  alias CodeMySpec.ContentSync.ProcessorResult

  @doc """
  Processes raw markdown content and converts it to HTML.

  Uses MDEx with the MDExMermaid plugin. Mermaid code blocks are transformed
  into renderable elements with a CDN script tag injected automatically.

  Always returns `{:ok, ProcessorResult.t()}` — errors are captured in the
  result struct, not as error tuples.
  """
  @spec process(raw_markdown :: String.t()) :: {:ok, ProcessorResult.t()}
  def process(raw_markdown) when is_binary(raw_markdown) do
    opts = [
      extension: [
        table: true,
        tasklist: true,
        strikethrough: true,
        autolink: true,
        footnotes: true,
        header_ids: ""
      ],
      plugins: [MDExMermaid]
    ]

    case MDEx.to_html(raw_markdown, opts) do
      {:ok, html_string} ->
        {:ok, ProcessorResult.success(raw_markdown, html_string)}

      {:error, error} ->
        parse_errors = %{
          error_type: error.__struct__ |> to_string() |> String.replace("Elixir.", ""),
          message: Exception.message(error),
          details: inspect(error),
          line: nil,
          context: nil
        }

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
end
