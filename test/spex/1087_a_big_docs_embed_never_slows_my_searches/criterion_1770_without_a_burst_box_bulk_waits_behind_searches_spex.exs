defmodule CodeMySpecSpex.Story1087.Criterion1770Spex do
  @moduledoc """
  Story 1087 — A big docs embed never slows my searches.
  Criterion 1770 — Without a burst box, bulk waits behind searches.

  Short of a configured burst runner, bulk work embeds locally, sharing
  the server's own capacity with search. A search arriving mid-import
  must still be answered before the import's next batch, not queued
  behind the whole job.
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

  defp next_bulk_batch_already_landed? do
    receive do
      {:embedded, _texts, :bulk} -> true
    after
      0 -> false
    end
  end

  spex "Without a burst box, bulk waits behind searches", criterion: 1770 do
    scenario "an agent searches while a large embedding job runs locally with no burst box" do
      given_ "a large embedding job is running on the server with no burst box configured",
              context do
        main = checkout(context, main?: true)
        harness_up(main)
        {tarball, checksum} = Fixtures.hex_tarball(sources())

        Req.Test.stub(
          CodeMySpec.Embeddings.HexPackageFetch,
          &Plug.Conn.send_resp(&1, 200, tarball)
        )

        write_lock(main, lock(checksum))
        manifest(main)

        import_task = Task.async(fn -> Fixtures.hex_doc_sweep_runs() end)
        assert_receive {:embedded, _texts, :bulk}, :timer.seconds(5)

        {:ok, Map.merge(context, %{main: main, import_task: import_task})}
      end

      when_ "an agent searches the project's docs", context do
        text = search(context.main, "hexdocs")
        next_batch_landed? = next_bulk_batch_already_landed?()

        {:ok, Map.merge(context, %{text: text, next_batch_landed?: next_batch_landed?})}
      end

      then_ "the search is answered before the next bulk batch", context do
        refute context.next_batch_landed?,
               "a further bulk batch finished before the search was answered"

        :ok = Task.await(context.import_task, :timer.seconds(30))
        {:ok, context}
      end
    end
  end
end
