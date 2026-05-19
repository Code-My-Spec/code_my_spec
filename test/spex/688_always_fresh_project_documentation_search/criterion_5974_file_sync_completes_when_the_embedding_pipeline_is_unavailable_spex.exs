defmodule CodeMySpecSpex.Story688.Criterion5974Spex do
  @moduledoc """
  Story 688 — Always-fresh project documentation search
  Criterion 5974 — File sync completes when the embedding pipeline is unavailable.

  Covers Rule "When the embedding pipeline (Ortex + sqlite_vec) is
  unavailable in the current runtime, file sync still succeeds —
  embedding is a best-effort step, never a hard dependency of sync."

  ## Observation surface

  The `/files` page's sync result panel is the engineer's signal
  that sync ran. Its presence with non-error content (and the
  absence of a sync_status==:error block) demonstrates that the
  pipeline did not bubble an embedding-unavailability error up
  through sync.

  This spec clears the configured `:embeddings_backend` for the
  duration of the test, so `Embeddings.available?/0` returns false
  the way it does on a `mix phx.server` runtime that doesn't have
  the embedding pipeline (Ortex + sqlite_vec).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @spec_path ".code_my_spec/spec/widget.spec.md"
  @spec_content """
  # Widget Context

  The Widget context exposes `create_widget/2`.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :force_embedding_pipeline_unavailable

  spex "Engineer can sync the project even on a runtime without the embedding pipeline" do
    scenario "sync succeeds and surfaces normal results when embeddings are unavailable" do
      given_ "the agent has written a new spec file", context do
        :ok = Environments.write_file(context.environment, @spec_path, @spec_content)
        {:ok, context}
      end

      when_ "the engineer clicks the sync button on /files", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the sync result panel renders without an error block", context do
        html = render(context.files_live)

        # Anchor: the success panel rendered.
        assert html =~ "Files"
        assert html =~ "Changed files"

        refute html =~ "Sync failed",
               "Expected sync to succeed without raising an embedding-unavailability error, got:\n#{html}"

        {:ok, context}
      end

      then_ "the file row appears in the projection", context do
        html = render(context.files_live)

        assert html =~ @spec_path,
               "Expected widget.spec.md to be present in the Files projection after sync, got:\n#{html}"

        {:ok, context}
      end
    end
  end

  defp force_embedding_pipeline_unavailable(_context) do
    prior = Application.get_env(:code_my_spec, :embeddings_backend)
    Application.delete_env(:code_my_spec, :embeddings_backend)

    ExUnit.Callbacks.on_exit(fn -> restore_embeddings_backend(prior) end)

    :ok
  end
  defp restore_embeddings_backend(nil), do: Application.delete_env(:code_my_spec, :embeddings_backend)
  defp restore_embeddings_backend(prior), do: Application.put_env(:code_my_spec, :embeddings_backend, prior)
end
