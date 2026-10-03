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
    :ok = Fixtures.embed_on_pgvector_queued(dir)
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

  # Every job this fixture's `OrtexServing` dispatches blocks until told
  # `:go`, so whichever remains blocked next (after releasing the one the
  # scenario is holding) names the queue's actual dispatch choice, with no
  # race against how fast the fake work underneath happens to run.
  defp release_remaining(import_task) do
    case Task.yield(import_task, 50) do
      nil ->
        receive do
          {:worker_blocked, pid, _kind, _texts} -> send(pid, :go)
        after
          0 -> :ok
        end

        release_remaining(import_task)

      {:ok, result} ->
        result
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
        assert_receive {:worker_blocked, batch_pid, :bulk, _texts}, :timer.seconds(5)

        {:ok, Map.merge(context, %{main: main, import_task: import_task, batch_pid: batch_pid})}
      end

      when_ "an agent searches the project's docs", context do
        test_pid = self()

        search_task =
          Task.async(fn ->
            send(test_pid, :search_calling)
            search(context.main, "hexdocs")
          end)

        assert_receive :search_calling, :timer.seconds(5)
        # A small margin for the GenServer to have actually enqueued the
        # search call before the held batch is released.
        Process.sleep(20)

        send(context.batch_pid, :go)

        # Whichever job the queue hands the worker next, held in turn
        # before it can run — this is the dispatch choice under test.
        assert_receive {:worker_blocked, next_pid, next_kind, _texts}, :timer.seconds(5)
        send(next_pid, :go)

        text = Task.await(search_task, :timer.seconds(10))

        {:ok, Map.merge(context, %{text: text, next_kind: next_kind})}
      end

      then_ "the search is answered before the next bulk batch", context do
        assert context.next_kind == :search,
               "a further bulk batch was dispatched before the search was"

        :ok = release_remaining(context.import_task)
        {:ok, context}
      end
    end
  end
end
