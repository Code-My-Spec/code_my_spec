defmodule CodeMySpec.Files.ComponentExtract do
  @moduledoc """
  Reads a component's identity out of a spec or implementation file.

  Pure string functions, kept apart from `ComponentSync` for one reason: the
  answers have to be computed where the bytes are.

  `ComponentSync` used to read every spec and impl file itself, at the moment it
  ran. On the light harness there is no working copy to read — and this is the
  one place where that failure is not merely unhelpful. A spec that yields no
  module name produces no component, and a full sync's `cleanup_removed/3`
  prunes components it did not see, so "cannot read the file" and "this
  component was deleted" arrive as the same event. `ComponentSync`'s own
  moduledoc warns about it, having been bitten once by a CRLF regression.

  So the extraction runs during the scan, on the machine holding the files, and
  the result travels in the File record. Same functions, same answers, decided
  somewhere they can be decided.

  ## CRLF

  Every extractor here normalises `\r\n` first. They anchor on `$`, and on a
  file written on Windows the `\r` sits between the value and the line end, so
  nothing matches — a spec that names no module, a component that never
  materialises, and a full sync that prunes it. That has happened once already.

  It is done inside each function rather than asked of callers, because "the
  caller forgot to normalise" and "this project has no such component" produce
  the same silence.
  """

  @doc "Line endings the extractors can anchor against."
  def normalize(content), do: String.replace(content, "\r\n", "\n")

  def extract_h1_module(raw) do
    content = normalize(raw)

    case Regex.run(~r/^# ([A-Z][a-zA-Z0-9_.]+)$/m, content) do
      [_, name] -> name
      _ -> nil
    end
  end

  def extract_type_section(raw) do
    content = normalize(raw)

    section_type =
      content
      |> String.split("\n")
      |> Enum.drop_while(&(!String.match?(&1, ~r/^## Type$/)))
      |> Enum.drop(1)
      |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.first()

    section_type ||
      case Regex.run(~r/^\*\*Type\*\*:\s*(.+)$/m, content) do
        [_, type] -> String.trim(type) |> String.downcase()
        nil -> nil
      end
  end

  def extract_intro_text(raw) do
    content = normalize(raw)

    content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^# [A-Z]/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  def extract_dependencies(raw) do
    content = normalize(raw)

    content
    |> String.split("\n")
    |> Enum.drop_while(&(!String.match?(&1, ~r/^## Dependencies/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(!String.match?(&1, ~r/^##/)))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(fn line ->
      line |> String.replace_prefix("- ", "") |> String.trim()
    end)
    |> Enum.reject(&(&1 == "" || &1 == "None"))
  end

  @doc """
  The module a `defmodule` declares. Files without one (scripts, `.exs`) have no
  component identity — the caller skips them.
  """
  def extract_defmodule(raw) do
    content = normalize(raw)

    case Regex.run(~r/^defmodule\s+([A-Z][a-zA-Z0-9_.]*)\s+do/m, content) do
      [_, name] -> name
      _ -> nil
    end
  end

  @doc """
  Whether a module is an Ecto schema.

  The one exception to "type lives in the spec". A schema declares what it is in
  its own first lines, and 59 components on this project were typed `module`
  because their spec had no `## Type` section and the changeset default took
  over — 49 of them having no spec file at all to put one in. That mistyping is
  not cosmetic: it gives them the module requirement graph instead of the schema
  one, and it defeats `validate_dependency_graph/1`'s schema exclusion, so every
  `belongs_to`/`has_many` pair between two of them is counted as an
  architectural cycle (`f198b227`).

  Matches `use Ecto.Schema` at the start of a line, so a mention inside a
  docstring or comment does not count.

  Takes file content, like `extract_defmodule/1` — both are called with the
  result of a successful read, and neither accepts `nil`. A nil here would mean
  the scanner had lost the content it just read, which should crash rather than
  quietly answer "not a schema".
  """
  @spec ecto_schema?(String.t()) :: boolean()
  def ecto_schema?(raw) when is_binary(raw) do
    raw
    |> normalize()
    |> String.match?(~r/^\s*use\s+Ecto\.Schema\b/m)
  end
end
