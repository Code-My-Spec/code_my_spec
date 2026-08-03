defmodule CodeMySpecSpex.Story127.Criterion5945Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5945 — mtime flip without content change leaves
  File.fingerprint unchanged and out-of-band consumers skip work.

  Covers Rule 8's mtime-decoupling half: a `touch` or git checkout
  flips the file's mtime but the content is byte-identical. Sync
  re-reads the file (because mtime moved), recomputes the fingerprint,
  and finds it unchanged. Out-of-band consumers comparing
  File.fingerprint to their last-seen fingerprint see no diff and
  skip work.

  In the in-memory test environment, `Environments.write_file/3`
  advances mtime on every write — including writes of byte-identical
  content. That's exactly the simulation we want for "mtime moved
  without a real content change."
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @impl_path "lib/fingerprint_stable.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees File.fingerprint stay stable when content is byte-identical across writes" do
    scenario "rewriting the same content advances mtime but leaves fingerprint unchanged" do
      given_ "the agent has written content A and the engineer has synced", context do
        :ok = Environments.write_file(context.environment, @impl_path, content_a())

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      when_ "the agent rewrites the file with byte-identical content A and the engineer re-syncs",
            context do
        :ok = Environments.write_file(context.environment, @impl_path, content_a())

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the impl row still carries the fingerprint of content A", context do
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_path}\"] [data-fingerprint=\"#{sha256(content_a())}\"]"
               )

        {:ok, context}
      end
    end
  end

  defp content_a do
    """
    defmodule FingerprintStable do
      @moduledoc "unchanged"
    end
    """
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
