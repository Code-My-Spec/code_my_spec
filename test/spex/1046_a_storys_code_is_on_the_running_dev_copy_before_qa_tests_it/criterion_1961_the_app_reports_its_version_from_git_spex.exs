defmodule CodeMySpecSpex.Story1046.Criterion1961Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1961 — The app reports its version from git.

  Rule: a promotion tags the commit it lands and commits nothing, so the
  version is read from git — the `vX.Y.Z` tag on the commit, or `X.Y.Z+N.gSHA`
  for N commits past it — and the running app reports that, not a literal in
  `mix.exs`. Observed where an operator reads it: `GET /health`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  setup :register_log_in_setup_account

  spex "The app reports its version from git", criterion: 1961 do
    scenario "the health check names the version git describes for this checkout" do
      given_ "the checkout the app was built from, as git describes it", context do
        root = Path.expand(".")

        {described, 0} =
          Environments.cmd(
            Environment.new(:local, root),
            "git",
            ["describe", "--tags", "--long", "--match", "v[0-9]*.[0-9]*.[0-9]*"],
            cd: root
          )

        {:ok, Map.put(context, :expected, from_describe(String.trim(described)))}
      end

      when_ "the app's health is read", context do
        conn = get(context.conn, "/health")
        {:ok, Map.put(context, :health, Jason.decode!(conn.resp_body))}
      end

      then_ "it reports git's version", context do
        assert context.health["version"] == context.expected,
               "the app reports #{inspect(context.health)}; git describes " <>
                 "this checkout as #{context.expected}"

        {:ok, context}
      end
    end
  end

  # On a tag: "X.Y.Z"; N commits past it: "X.Y.Z+N.gSHA".
  defp from_describe(described) do
    [_, version, count, sha] = Regex.run(~r/^v(\d+\.\d+\.\d+)-(\d+)-(g[0-9a-f]+)$/, described)
    version(version, count, sha)
  end

  defp version(version, "0", _sha), do: version
  defp version(version, count, sha), do: "#{version}+#{count}.#{sha}"
end
