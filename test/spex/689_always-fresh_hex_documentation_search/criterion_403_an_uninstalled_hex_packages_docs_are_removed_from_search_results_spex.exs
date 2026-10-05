defmodule CodeMySpecSpex.Story689.Criterion5979Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 403 — An uninstalled hex package's docs are removed from
  search results.

  The docs stay stored (another project may lock the same version), but a
  project that no longer locks the package no longer finds them.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessedKnowledgeHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    dir = CodeMySpec.TempFile.owned_dir("test")
    :ok = Fixtures.embed_on_pgvector(dir)
    # hex.pm is fetched inside the embed pool, not this process.
    Req.Test.set_req_test_to_shared()
    :ok
  end

  defp lock(version, checksum),
    do:
      ~s(%{\n  "swept_pkg": {:hex, :swept_pkg, "#{version}", "chk", [:mix], [], "hexpm", "#{checksum}"}\n}\n)

  defp source(doc), do: %{"lib/swept.ex" => "defmodule Swept do\n  @moduledoc \"#{doc}\"\nend\n"}

  # hex.pm, serving each version's tarball at its own URL.
  defp serve(tarballs) do
    Req.Test.stub(CodeMySpec.Embeddings.HexPackageFetch, fn conn ->
      [_, version] = Regex.run(~r/swept_pkg-(.+)\.tar$/, conn.request_path)
      Plug.Conn.send_resp(conn, 200, Map.fetch!(tarballs, version))
    end)
  end

  spex "Agent does not see uninstalled hex packages in search results", criterion: 403 do
    scenario "the main copy drops swept_pkg from mix.lock" do
      given_ "swept_pkg's docs are searchable, and mix.lock no longer locks it", context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball, checksum} = Fixtures.hex_tarball(source("Swept sweeps the floor."))
        serve(%{"1.0.0" => tarball})
        write_lock(main, lock("1.0.0", checksum))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "Swept sweeps the floor."
        write_lock(main, "%{}\n")
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest", context do
        manifest(context.main)
        {:ok, context}
      end

      then_ "search no longer finds swept_pkg's documentation", context do
        refute search(context.main, "hexdocs") =~ "Swept sweeps the floor."
        {:ok, context}
      end
    end
  end
end
