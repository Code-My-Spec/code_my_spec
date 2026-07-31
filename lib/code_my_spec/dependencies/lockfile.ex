defmodule CodeMySpec.Dependencies.Lockfile do
  @moduledoc """
  Reads `mix.lock` into a dependency set.

  The lock is the authoritative statement of *which packages at which versions
  this project depends on*. It is written atomically by `mix deps.get` before
  any unpacking happens, which is what makes it a better trigger for dependency
  work than the `deps/` tree it describes — the tree is being built while the
  lock is already complete and correct.

  ## Parsed, not evaluated

  `Code.string_to_quoted/1` rather than `Code.eval_file/1`. Mix itself evaluates
  the lock, and doing the same here would not be a new risk in a system that
  already runs `mix` against these projects. It would, however, mean a
  syntactically valid lock could run code during what reads like a file parse,
  and there is no reason to accept that when the file is pure data.

  One caveat that comes with parsing: the quoted-keyword keys in a lock
  (`"bandit": {...}`) are atoms, so parsing interns one atom per package. Bounded
  by the developer's own lock file and on the same trust footing as `mix.exs`.
  """

  @type entry :: %{name: String.t(), version: String.t(), source: String.t()}

  @doc """
  Parse lock file contents into one entry per package.

  Returns `{:error, :unparseable}` rather than a partial set — half a dependency
  list is indistinguishable from a project that shed its other dependencies, and
  acting on that would drop hexdocs for everything the parse failed to reach.
  """
  @spec parse(String.t()) :: {:ok, [entry()]} | {:error, :unparseable}
  def parse(contents) when is_binary(contents) do
    # `emit_warnings: false` because a lock writes its keys as quoted keywords
    # (`"bandit": {...}`) and Elixir warns that the quotes are unnecessary — once
    # per package, so parsing our own lock emits 109 warnings about the format
    # Mix itself wrote. Nothing here can act on them.
    case Code.string_to_quoted(contents, emit_warnings: false) do
      {:ok, {:%{}, _meta, pairs}} when is_list(pairs) ->
        {:ok, pairs |> Enum.flat_map(&entry/1) |> Enum.sort_by(& &1.name)}

      _ ->
        {:error, :unparseable}
    end
  end

  # `{:hex, :name, "1.2.3", inner_checksum, build_tools, deps, repo, outer_checksum}`
  defp entry({name, {:{}, _, [:hex, _atom_name, version | _rest]}}) when is_binary(version) do
    [%{name: to_string(name), version: version, source: "hex"}]
  end

  # `{:git, url, sha, opts}` — the sha is the version, because for a git dep it
  # is the only thing that actually pins anything. A branch ref moves.
  defp entry({name, {:{}, _, [:git, _url, sha | _rest]}}) when is_binary(sha) do
    [%{name: to_string(name), version: sha, source: "git"}]
  end

  defp entry({name, {:{}, _, [source | _rest]}}) when is_atom(source) do
    [%{name: to_string(name), version: nil, source: to_string(source)}]
  end

  # Anything the lock format grows that this does not recognise is skipped
  # rather than guessed at. It shows up as a package with no projected docs,
  # which is visible, instead of as a wrong version, which is not.
  defp entry(_pair), do: []
end
