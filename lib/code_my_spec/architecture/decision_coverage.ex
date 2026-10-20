defmodule CodeMySpec.Architecture.DecisionCoverage do
  @moduledoc """
  Whether the architecture decision records still describe the dependencies the
  project actually has (issue bce21d41).

  An ADR declares what it covers in its frontmatter, because matching package
  names against prose cannot answer the question (`cloak_ecto` is written
  "Cloak Ecto", `phoenix_live_view` never appears in `liveview.md`):

      ---
      deps: [phoenix, phoenix_ecto, phoenix_html]
      declined: [wallaby]
      ---

  The rule, from John's decision of 2026-10-20:

    * every **direct** dependency in `mix.exs` is covered by an ADR — a framework's
      ADR lists the packages that arrived with it (`jason` and `gettext` with
      Phoenix); `mix.lock` transitives are not considered;
    * an ADR need not cover any dependency (DaisyUI, Elixir, phx.gen.auth and
      Hetzner are decisions that bring in no package) and is never flagged for it;
    * an ADR covering a dependency that is no longer in `mix.exs` is **stale**;
    * an ADR may **decline** a dependency; declining one that is present in
      `mix.exs` is a contradiction.

  Pure: it takes the text of `mix.exs` and of each ADR, read once by the caller,
  so a check costs one read per file rather than one per dependency.
  """

  @type finding ::
          {:uncovered, String.t()}
          | {:stale, path :: String.t(), String.t()}
          | {:declined_but_present, path :: String.t(), String.t()}

  @doc "The direct dependencies `mix.exs` declares, by package name."
  @spec direct_deps(String.t()) :: [String.t()]
  def direct_deps(mix_exs) when is_binary(mix_exs) do
    case String.split(mix_exs, ~r/defp\s+deps\b/, parts: 2) do
      [_before, after_deps] ->
        ~r/^\s*\{:([a-z][a-z0-9_]*),/m
        |> Regex.scan(first_function(after_deps), capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      [_no_deps] ->
        []
    end
  end

  # The body of `defp deps`: up to the next function definition at the same
  # indentation.
  defp first_function(text) do
    case Regex.split(~r/^  defp?\s/m, text, parts: 2) do
      [body | _] -> body
    end
  end

  @doc "What an ADR's frontmatter says it covers and declines."
  @spec frontmatter(String.t()) :: %{deps: [String.t()], declined: [String.t()]}
  def frontmatter(text) when is_binary(text) do
    case Regex.run(~r/\A---\n(.*?)\n---(?:\n|\z)/s, text, capture: :all_but_first) do
      [block] -> %{deps: list(block, "deps"), declined: list(block, "declined")}
      nil -> %{deps: [], declined: []}
    end
  end

  defp list(block, key) do
    case Regex.run(~r/^#{key}:\s*\[(.*?)\]\s*$/m, block, capture: :all_but_first) do
      [items] ->
        items
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  @doc """
  Check `adrs` (path => text) against `mix_exs`. Findings come back sorted:
  uncovered dependencies, then stale coverage, then declined-but-present.
  """
  @spec check(String.t(), %{String.t() => String.t()}) :: [finding()]
  def check(mix_exs, adrs) when is_binary(mix_exs) and is_map(adrs) do
    present = mix_exs |> direct_deps() |> MapSet.new()
    declared = Map.new(adrs, fn {path, text} -> {path, frontmatter(text)} end)

    covered =
      declared |> Enum.flat_map(fn {_path, %{deps: deps}} -> deps end) |> MapSet.new()

    uncovered =
      present |> MapSet.difference(covered) |> Enum.sort() |> Enum.map(&{:uncovered, &1})

    stale =
      for {path, %{deps: deps}} <- Enum.sort(declared),
          dep <- deps,
          not MapSet.member?(present, dep),
          do: {:stale, path, dep}

    contradicted =
      for {path, %{declined: declined}} <- Enum.sort(declared),
          dep <- declined,
          MapSet.member?(present, dep),
          do: {:declined_but_present, path, dep}

    uncovered ++ stale ++ contradicted
  end

  @doc "A report an agent can act on; empty findings read as covered."
  @spec report([finding()]) :: String.t()
  def report([]),
    do: "Every direct dependency in mix.exs is covered by an ADR, and no ADR is stale."

  def report(findings) do
    lines =
      Enum.map(findings, fn
        {:uncovered, dep} ->
          "- `#{dep}` is a direct dependency no ADR covers: add it to the `deps:` frontmatter of the ADR it arrived with, or write one."

        {:stale, path, dep} ->
          "- #{path} covers `#{dep}`, which is no longer in mix.exs: the decision is stale. Supersede the ADR, or move `#{dep}` from `deps:` to `declined:`."

        {:declined_but_present, path, dep} ->
          "- #{path} declines `#{dep}`, but it is in mix.exs: either the decision or the dependency is wrong."
      end)

    "#{length(findings)} decision finding(s):\n\n" <> Enum.join(lines, "\n")
  end
end
