defmodule CodeMySpecSpex.Story127.Criterion5931Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5931 — Content edit produces a new fingerprint and triggers
  downstream consumers.

  Covers Rule "A relevant filesystem event triggers the full chain."
  When a tracked file's content changes and sync runs, the File
  projection shows a new fingerprint AND downstream consumers
  (FileComponentSync, validity derivation) re-run against the fresh
  content. The user-visible proof is: after renaming the module an
  implementation declares, the Files page shows the new fingerprint AND
  the row names the newly discovered component.

  This builds on 5944 (which asserts fingerprint refresh only) by
  also asserting the consumer-side effect.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts

  @impl_v1_path "lib/example_context.ex"
  @impl_v2_path "lib/renamed_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees a content edit ripple through fingerprint AND downstream consumers",
    criterion: 86 do
    scenario "renaming a module re-derives the component after sync" do
      given_ "the agent has written v1 code and the engineer has synced", context do
        :ok = ExecutionContexts.write_file(context.execution_context, @impl_v1_path, impl_v1())

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "the v1 file is showing its v1 fingerprint and ExampleContext as its component",
             context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_v1_path}\"] [data-fingerprint=\"#{sha256(impl_v1())}\"]"
               )

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@impl_v1_path}\"] [data-test='file-component']",
                 "ExampleContext"
               )

        {:ok, context}
      end

      given_ "the agent has renamed the module", context do
        :ok = ExecutionContexts.delete_file(context.execution_context, @impl_v1_path)
        :ok = ExecutionContexts.write_file(context.execution_context, @impl_v2_path, impl_v2())
        {:ok, context}
      end

      when_ "the engineer re-syncs from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the renamed file's row carries a new fingerprint and names the new component",
            context do
        # Fingerprint side — proves classify+upsert observed the new bytes.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_v2_path}\"] [data-fingerprint=\"#{sha256(impl_v2())}\"]"
               )

        # Consumer side — ComponentSync discovered a component for the
        # NEW module name, proving the consumer re-ran on the edit.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_v2_path}\"] [data-test='file-component']",
                 "RenamedContext"
               )

        # Old artifacts no longer linger.
        refute has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_v1_path}\"]"
               )

        {:ok, context}
      end
    end
  end

  defp impl_v1 do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end

  defp impl_v2 do
    """
    defmodule RenamedContext do
      @moduledoc false
    end
    """
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
