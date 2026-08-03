defmodule CodeMySpecSpex.Story689.Criterion5982Spex do
  @moduledoc """
  Story 689 — Always-fresh hex documentation search
  Criterion 5982 — Sync completes when the embedding pipeline is
  unavailable.

  Covers Rule "When the embedding pipeline (Ortex + sqlite_vec) is
  unavailable in the current runtime, hex doc projection and sync
  still succeed."

  ## Observation surface

  Same approach as story 688's graceful-unavailability scenario.
  Clears `:embeddings_backend` for the duration of the test so
  `Embeddings.available?/0` returns false the way it does on a
  `mix phx.server` runtime without the CLI binary, then asserts
  that sync still produces a populated success panel.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @hex_doc_path ".code_my_spec/hex_docs/phoenix/phoenix.md"
  @hex_doc_content """
  # Phoenix

  Phoenix.Endpoint provides the HTTP entry point.
  """

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :force_embedding_pipeline_unavailable

  spex "Engineer can sync hex docs even on a runtime without the embedding pipeline" do
    scenario "sync succeeds when phoenix is projected but embeddings are unavailable" do
      given_ "phoenix's projected markdown is present in the working tree", context do
        :ok = Environments.write_file(context.environment, @hex_doc_path, @hex_doc_content)
        {:ok, context}
      end

      when_ "the engineer clicks sync on /files", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

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

      then_ "the projected hex doc file appears in the Files projection", context do
        html = render(context.files_live)

        assert html =~ @hex_doc_path,
               "Expected phoenix.md to be present in the Files projection after sync, got:\n#{html}"

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
