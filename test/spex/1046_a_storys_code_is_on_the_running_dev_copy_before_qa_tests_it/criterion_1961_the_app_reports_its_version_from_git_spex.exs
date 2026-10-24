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

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext

  setup :register_log_in_setup_account

  spex "The app reports its version from git", criterion: 1961 do
    scenario "the health check names the version git describes for the commit it was built from" do
      when_ "the app's health is read", context do
        conn = get(context.conn, "/health")
        {:ok, Map.put(context, :health, Jason.decode!(conn.resp_body))}
      end

      # Pinned to the exact commit the reported version itself names, not to
      # `HEAD` at test time: the version was computed once, when `mix.exs`
      # ran `git describe` at this VM's own boot, and `HEAD` can move after
      # that -- a merge, a tag from another promotion -- while a long full
      # spex run is still going. Comparing against live `HEAD` then failed
      # on state, not on a code defect (issue d5ca52da).
      then_ "it reports git's version for that exact commit", context do
        root = Path.expand(".")
        ref = ref_from_version(context.health["version"])

        {described, 0} =
          ExecutionContexts.cmd(
            ExecutionContext.new(:local, root),
            "git",
            ["describe", "--tags", "--long", "--match", "v[0-9]*.[0-9]*.[0-9]*", ref],
            cd: root
          )

        expected = from_describe(String.trim(described))

        assert context.health["version"] == expected,
               "the app reports #{inspect(context.health)}; git describes " <>
                 "#{ref} as #{expected}"

        {:ok, context}
      end
    end
  end

  # The version string names its own commit: a tag exactly ("X.Y.Z") or N
  # commits past one ("X.Y.Z+N.gSHA") -- `from_describe/1`'s own encoding,
  # inverted so the commit can be re-described independently of `HEAD`.
  defp ref_from_version(version),
    do: ~r/^\d+\.\d+\.\d+\+\d+\.g([0-9a-f]+)$/ |> Regex.run(version) |> ref(version)

  defp ref([_, sha], _version), do: sha
  defp ref(nil, version), do: "v#{version}"

  # On a tag: "X.Y.Z"; N commits past it: "X.Y.Z+N.gSHA".
  defp from_describe(described) do
    [_, version, count, sha] = Regex.run(~r/^v(\d+\.\d+\.\d+)-(\d+)-(g[0-9a-f]+)$/, described)
    version(version, count, sha)
  end

  defp version(version, "0", _sha), do: version
  defp version(version, count, sha), do: "#{version}+#{count}.#{sha}"
end
