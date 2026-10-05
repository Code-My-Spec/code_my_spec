defmodule CodeMySpecSpex.Story689.Criterion5977Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 401 — A newly installed hex package becomes searchable.

  The server reads a project's dependencies from its main copy's mix.lock,
  fetches each locked package from hex.pm once, and embeds its docs for
  every project that locks that version (577de9bb).
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

  spex "Agent finds newly installed hex package documentation in semantic search",
    criterion: 401 do
    scenario "the main copy's mix.lock gains a package" do
      given_ "the main copy locks swept_pkg 1.0.0, which hex.pm serves", context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball, checksum} = Fixtures.hex_tarball(source("Swept sweeps the floor."))
        serve(%{"1.0.0" => tarball})
        write_lock(main, lock("1.0.0", checksum))
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest and the hex docs pass runs", context do
        manifest(context.main)
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, context}
      end

      then_ "search finds swept_pkg's documentation", context do
        assert search(context.main, "hexdocs") =~ "Swept sweeps the floor."
        {:ok, context}
      end
    end
  end
end
