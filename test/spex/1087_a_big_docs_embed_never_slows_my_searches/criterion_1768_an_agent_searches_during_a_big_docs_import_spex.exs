defmodule CodeMySpecSpex.Story1087.Criterion1768Spex do
  @moduledoc """
  Story 1087 — A big docs embed never slows my searches.
  Criterion 1768 — An agent searches during a big docs import.

  A search is one short query; a big import is many chunks. The search must
  not wait behind the import.
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
    Req.Test.set_req_test_to_shared()
    :ok
  end

  @file_count 50

  defp sources do
    Map.new(1..@file_count, fn n ->
      {"lib/module_#{n}.ex",
       "defmodule BigDocs.Module#{n} do\n  @moduledoc \"Module #{n} does its part of a big job.\"\nend\n"}
    end)
  end

  defp lock(checksum),
    do:
      ~s(%{\n  "big_docs_pkg": {:hex, :big_docs_pkg, "1.0.0", "chk", [:mix], [], "hexpm", "#{checksum}"}\n}\n)

  spex "An agent's search is answered quickly during a big docs import", criterion: 1768 do
    scenario "thousands of hex docs are being embedded while an agent searches" do
      given_ "a large hex package is pinned and ready to embed", context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball, checksum} = Fixtures.hex_tarball(sources())

        Req.Test.stub(
          CodeMySpec.Embeddings.HexPackageFetch,
          &Plug.Conn.send_resp(&1, 200, tarball)
        )

        write_lock(main, lock(checksum))
        manifest(main)
        {:ok, Map.put(context, :main, main)}
      end

      when_ "the import runs and an agent searches the project's docs at the same time",
            context do
        import_task = Task.async(fn -> Fixtures.hex_doc_sweep_runs() end)

        start_ms = System.monotonic_time(:millisecond)
        text = search(context.main, "hexdocs")
        elapsed_ms = System.monotonic_time(:millisecond) - start_ms

        :ok = Task.await(import_task, :timer.seconds(30))

        {:ok, Map.merge(context, %{elapsed_ms: elapsed_ms, text: text})}
      end

      then_ "results come back within a second", context do
        assert context.elapsed_ms < 1000,
               "search took #{context.elapsed_ms}ms during a big import"

        {:ok, context}
      end
    end
  end
end
