defmodule CodeMySpec.ContentPublishing.FrontmatterParser do
  @moduledoc """
  Extracts YAML frontmatter + body from a content file, by format:

    * **markdown** (`.md`) — YAML between leading `---` fences, then the body.
    * **html** (`.html`) — YAML inside the **first** leading `<!-- … -->`
      comment (so the file stays a valid, browser-openable HTML document),
      then the body with that comment stripped.

  Parse failures are returned as data (`{:error, detail}`) — never raised — so
  a single malformed file degrades to an error row instead of aborting a whole
  sync (story 712, criterion 6269).
  """

  @type meta :: %{optional(String.t()) => any()}
  @type error_detail :: %{type: atom(), message: String.t()}
  @type format :: :markdown | :html

  @doc "Parse `content` of the given `format` into `{:ok, meta, body}` or `{:error, detail}`."
  @spec parse(String.t(), format()) :: {:ok, meta(), String.t()} | {:error, error_detail()}
  def parse(content, :markdown) when is_binary(content) do
    case Regex.run(~r/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/s, content) do
      [_, yaml, body] -> decode(yaml, body)
      _ -> {:error, %{type: :missing_frontmatter, message: "No YAML frontmatter found"}}
    end
  end

  def parse(content, :html) when is_binary(content) do
    case Regex.run(~r/\A\s*<!--\s*(.*?)\s*-->\s*(.*)\z/s, content) do
      [_, yaml, body] -> decode(yaml, body)
      _ -> {:error, %{type: :missing_frontmatter, message: "No HTML frontmatter comment found"}}
    end
  end

  @doc "Map a file extension to a parser format."
  @spec format_for(String.t()) :: format()
  def format_for(path) do
    case Path.extname(path) do
      ".html" -> :html
      _ -> :markdown
    end
  end

  defp decode(yaml, body) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = meta} ->
        {:ok, meta, body}

      {:ok, _other} ->
        {:error, %{type: :invalid_frontmatter, message: "YAML frontmatter is not a mapping"}}

      {:error, error} ->
        {:error,
         %{type: :yaml_parse_error, message: "Invalid YAML frontmatter: #{Exception.message(error)}"}}
    end
  end
end
