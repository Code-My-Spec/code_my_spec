defmodule CodeMySpecWeb.TheBundleImportsOnlyWhatItCanResolveTest do
  @moduledoc """
  Every package the JS bundle imports resolves where esbuild looks: `deps/` or
  the build path (`NODE_PATH` in `config/config.exs`).

  This repo has no npm install step. Story 1092 imported the `echarts` npm
  package, the bundle failed to build, `app.js` was never written, and every
  LiveView page in dev ran without JavaScript: no question could be answered
  anywhere (2026-10-12). A browser library is vendored under
  `priv/static/vendor/`, as sigma and echarts are.
  """
  use ExUnit.Case, async: true

  @import ~r/^\s*(?:import\s+(?:[^"']*\s+from\s+)?|export\s+[^"']*\s+from\s+)["']([^"'.\/][^"']*)["']/m

  test "no bare import names a package the build cannot find" do
    unresolved =
      for path <- Path.wildcard("assets/js/**/*.js"),
          [_, name] <- Regex.scan(@import, File.read!(path)),
          not resolvable?(name),
          do: "#{path}: #{name}"

    assert unresolved == [],
           "imported but not in deps/ or the build path, so esbuild cannot bundle it; " <>
             "vendor it under priv/static/vendor/ instead:\n" <> Enum.join(unresolved, "\n")
  end

  defp resolvable?(name) do
    package = name |> String.split("/") |> hd()

    File.dir?(Path.join("deps", package)) or
      File.dir?(Path.join(Mix.Project.build_path(), package))
  end
end
