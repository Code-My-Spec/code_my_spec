defmodule CodeMySpec.Files.ComponentExtract do
  @moduledoc """
  Reads a module's identity out of an implementation file, during the scan,
  where the bytes are. The result travels in the File record, so a sync on a
  server with no working copy never has to open the file.

  Every extractor normalises `\r\n` first: they anchor on `$`, and on a file
  written on Windows the `\r` sits between the value and the line end.
  """

  @doc "Fingerprint a nonempty module body independently of its declared name."
  def rename_fingerprint(content) do
    case Code.string_to_quoted(content) do
      {:ok, {:defmodule, _, [_name, [do: {:__block__, _, []}]]}} ->
        nil

      {:ok, {:defmodule, _, [_name, [do: body]]}} when not is_nil(body) ->
        body
        |> Macro.to_string()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      _ ->
        nil
    end
  end

  @doc "Line endings the extractors can anchor against."
  def normalize(content), do: String.replace(content, "\r\n", "\n")

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

  The one type code can say. A schema declares what it is in
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
