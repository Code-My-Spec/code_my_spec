defmodule CodeMySpecSpex.Story1087.Criterion1769Spex do
  @moduledoc """
  Story 1087 — A big docs embed never slows my searches.
  Criterion 1769 — Bulk work goes to the burst box.

  Retired until the burst box was real (story 877/992); restored now that
  it is. A bulk embed is dispatched through `InFlightCalls.call(CodeMySpec.EmbedPool,
  ...)` — the pool's own configured backend decides where that work
  actually runs. In production, with a Hetzner burst box configured, that
  backend is `CodeMySpec.Embeddings.HetznerFlameBackend`, which boots a
  real remote runner on the box (proven live against a real account —
  story 877/992's own follow-on). Here, `CodeMySpecSpex.RecordingFlameBackend`
  stands in for it: a thin wrapper around `FLAME.LocalBackend` that reports
  its own `remote_boot/1` — the one call every `FLAME.Backend` makes to
  actually go somewhere and run a job. Seeing that report is "work went to
  the burst box," without needing SSH or a real Hetzner account in a spex.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Embeddings.ProjectKnowledgeReconciler
  alias CodeMySpecSpex.RecordingFlameBackend
  alias CodeMySpecTest.RecordingEmbeddingServing

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    previous = Application.get_env(:code_my_spec, :embedding_serving)
    Application.put_env(:code_my_spec, :embedding_serving, RecordingEmbeddingServing)
    RecordingEmbeddingServing.listen(self())
    RecordingFlameBackend.listen(self())

    start_supervised!(
      {FLAME.Pool,
       name: CodeMySpec.EmbedPool, min: 0, max: 1, backend: RecordingFlameBackend}
    )

    on_exit(fn ->
      RecordingEmbeddingServing.reset()
      RecordingFlameBackend.reset()
      restore_embedding_serving(previous)
    end)

    :ok
  end

  defp restore_embedding_serving(nil), do: Application.delete_env(:code_my_spec, :embedding_serving)
  defp restore_embedding_serving(value), do: Application.put_env(:code_my_spec, :embedding_serving, value)

  defp read(_path), do: {:ok, "defmodule Big do\n  @moduledoc \"big enough to bulk embed.\"\nend\n"}

  spex "Bulk embedding work reaches the pool's configured burst backend", criterion: 1769 do
    scenario "a project's knowledge is reconciled with a burst backend configured" do
      given_ "a project ready to have its knowledge reconciled", context do
        # given: already true — `setup :setup_active_project` creates the
        # project; `reconcile/3` is stateless about what's "pending," it
        # computes that fresh from the `desired` map the `when_` step builds.
        {:ok, Map.put(context, :project_id, context.scope.active_project_id)}
      end

      when_ "the project's knowledge is reconciled", context do
        desired = %{"lib/big.ex" => "fingerprint-1"}
        result = ProjectKnowledgeReconciler.reconcile(context.project_id, desired, &read/1)
        {:ok, Map.put(context, :result, result)}
      end

      then_ "the embed call booted the pool's own configured backend", context do
        assert_received {CodeMySpecSpex.RecordingFlameBackend, :booted},
                         "the bulk embed never reached the pool's backend boot step — it ran without going through the burst path at all"

        {:ok, context}
      end

      then_ "the file was embedded through it", context do
        assert {:ok, %{embedded: 1}} = context.result
        assert_received {:embedded, _texts, :bulk}
        {:ok, context}
      end
    end
  end
end
