defmodule CodeMySpecSpex.Story689.Criterion5978Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 402 — An upgraded hex package's new version content replaces
  the old in search results.

  Search returns docs for exactly the versions the project locks. An
  upgrade is a new version: its docs are fetched and embedded, and the old
  version's stop being this project's.
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

  spex "Agent sees upgraded hex package content in search", criterion: 402 do
    scenario "the main copy upgrades swept_pkg from 1.0.0 to 2.0.0" do
      given_ "swept_pkg 1.0.0's docs are searchable, and mix.lock now locks 2.0.0", context do
        main = checkout(context, main?: true)
        harness_up(main)
        {old, old_checksum} = Fixtures.hex_tarball(source("Swept sweeps the floor."))
        {new, new_checksum} = Fixtures.hex_tarball(source("Swept now mops as well."))
        serve(%{"1.0.0" => old, "2.0.0" => new})

        write_lock(main, lock("1.0.0", old_checksum))
        manifest(main)
        :ok = Fixtures.hex_doc_sweep_runs()
        assert search(main, "hexdocs") =~ "Swept sweeps the floor."

        write_lock(main, lock("2.0.0", new_checksum))
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest and the hex docs pass runs", context do
        manifest(context.main)
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, context}
      end

      then_ "search has 2.0.0's docs and not 1.0.0's", context do
        text = search(context.main, "hexdocs")
        assert text =~ "Swept now mops as well."
        refute text =~ "Swept sweeps the floor."
        {:ok, context}
      end
    end
  end
end
