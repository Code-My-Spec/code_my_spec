#!/usr/bin/env elixir

# Strips drift-prone prose from `*.spec.md` files under `.code_my_spec/spec/`.
#
# Keeps:
#   - H1 title + intro paragraph (everything before the first `## `)
#   - Whitelisted H2 sections: Type, Dependencies, Components, Delegates, Fields
#
# Drops:
#   - Everything else (Functions, Process steps, Test Assertions, Examples,
#     Migration notes, etc.) — these rot fastest as code drifts.
#
# Architecture graph metadata (Type + Dependencies) and one-line component /
# delegate / field lists survive. `require_specs: false` in project config
# makes the rest of the registry's required sections optional, so trimmed
# specs still validate.
#
# Run from repo root:
#
#     mix run scripts/strip_spec_prose.exs
#
# Idempotent. Re-running on already-stripped files makes no further changes.

keep_sections = MapSet.new(["Type", "Dependencies", "Components", "Delegates", "Fields"])

strip = fn content ->
  parts = String.split(content, ~r/^(?=## )/m, trim: false)

  case parts do
    [header] ->
      header

    [header | sections] ->
      kept =
        Enum.filter(sections, fn section ->
          case Regex.run(~r/^## (\S+)/, section) do
            [_, name] -> MapSet.member?(keep_sections, name)
            _ -> false
          end
        end)

      [header | kept]
      |> Enum.join("")
      |> String.trim_trailing()
      |> Kernel.<>("\n")
  end
end

spec_paths = Path.wildcard(".code_my_spec/spec/**/*.spec.md")

{changed, unchanged} =
  Enum.reduce(spec_paths, {0, 0}, fn path, {changed, unchanged} ->
    original = File.read!(path)
    stripped = strip.(original)

    if stripped != original do
      File.write!(path, stripped)
      IO.puts("stripped: #{path}")
      {changed + 1, unchanged}
    else
      {changed, unchanged + 1}
    end
  end)

IO.puts("")
IO.puts("Done. Stripped #{changed} file(s); #{unchanged} unchanged.")
