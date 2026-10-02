defmodule CodeMySpecSpex.Story689.Criterion1695Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search.
  Criterion 1695 — A changed mix.lock on the main copy updates the project's dependencies
  without waiting for the sweep.

  A dependency added this morning should have its docs searchable by the
  next hex docs pass, not after the next 15-minute lockfile sweep too.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessedKnowledgeHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    {:ok, dir} = Briefly.create(directory: true)
    :ok = Fixtures.embed_on_pgvector(dir)
    # hex.pm is fetched inside the embed pool, not this process.
    Req.Test.set_req_test_to_shared()
    :ok
  end

  @lib %{"lib/swept.ex" => "defmodule Swept do\n  @moduledoc \"Swept sweeps the floor.\"\nend\n"}

  defp lock(checksum),
    do:
      ~s(%{\n  "swept_pkg": {:hex, :swept_pkg, "1.0.0", "chk", [:mix], [], "hexpm", "#{checksum}"}\n}\n)

  spex "A changed mix.lock reaches the dependencies from its manifest", criterion: 1695 do
    scenario "the main copy adds a dependency" do
      given_ "the main copy's mix.lock now locks swept_pkg, and hex.pm serves it", context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball, checksum} = Fixtures.hex_tarball(@lib)

        Req.Test.stub(
          CodeMySpec.Embeddings.HexPackageFetch,
          &Plug.Conn.send_resp(&1, 200, tarball)
        )

        write_lock(main, lock(checksum))
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the harness sends its manifest, and the hex docs pass runs", context do
        manifest(context.main)
        :ok = Fixtures.hex_doc_sweep_runs()
        {:ok, context}
      end

      then_ "the new dependency's docs are searchable", context do
        assert search(context.main, "hexdocs") =~ "Swept sweeps the floor."
        {:ok, context}
      end
    end
  end
end
