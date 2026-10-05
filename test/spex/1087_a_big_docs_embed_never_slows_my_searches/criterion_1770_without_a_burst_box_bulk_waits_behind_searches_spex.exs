defmodule CodeMySpecSpex.Story1087.Criterion1770Spex do
  @moduledoc """
  Story 1087 — A big docs embed never slows my searches.
  Criterion 1770 — Without a burst box, bulk waits behind searches.

  Retired until the burst box was real; restored now that story 877/992's
  work makes "with a burst box" an actual, provable alternative (criterion
  1769) rather than the only path. This is that alternative's complement —
  the fallback this story's own notes describe: "With no burst box, batch
  falls back to the server under search-first priority." Criterion 1768
  proves the same property end to end through a hex doc import; this
  proves it holds for the project reconciler's own bulk call site too, not
  just that one path.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Embeddings
  alias CodeMySpec.Embeddings.ProjectKnowledgeReconciler
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    dir = CodeMySpec.TempFile.owned_dir("test")
    :ok = Fixtures.embed_on_pgvector(dir)
    :ok
  end

  @chunk_count 20

  defp read(_path),
    do: {:ok, "defmodule BigDocs do\n  @moduledoc \"a lot of chunks to bulk embed.\"\nend\n"}

  defp desired, do: Map.new(1..@chunk_count, &{"lib/module_#{&1}.ex", "fingerprint-#{&1}"})

  spex "A concurrent search is not held up behind a bulk reconcile with no burst box",
    criterion: 1770 do
    scenario "a project's knowledge is reconciled in bulk while an agent searches" do
      given_ "a project ready to have its knowledge reconciled", context do
        # given: already true — `setup :setup_active_project` creates the
        # project; `reconcile/3` is stateless about what's "pending," it
        # computes that fresh from the `desired` map the `when_` step builds.
        {:ok, Map.put(context, :project_id, context.scope.active_project_id)}
      end

      when_ "the bulk reconcile runs and an agent searches at the same time", context do
        bulk_task =
          Task.async(fn ->
            ProjectKnowledgeReconciler.reconcile(context.project_id, desired(), &read/1)
          end)

        start_ms = System.monotonic_time(:millisecond)
        search_result = Embeddings.search(context.scope, "module")
        elapsed_ms = System.monotonic_time(:millisecond) - start_ms

        bulk_result = Task.await(bulk_task, :timer.seconds(30))

        {:ok,
         Map.merge(context, %{
           elapsed_ms: elapsed_ms,
           search_result: search_result,
           bulk_result: bulk_result
         })}
      end

      then_ "the search answers within a second, not behind the bulk queue", context do
        assert context.elapsed_ms < 1000,
               "search took #{context.elapsed_ms}ms while a bulk reconcile (no burst box) was running"

        assert match?({:ok, _}, context.search_result)
        {:ok, context}
      end

      then_ "the bulk reconcile still finished, falling back to the same local server", context do
        assert {:ok, %{embedded: @chunk_count}} = context.bulk_result
        {:ok, context}
      end
    end
  end
end
