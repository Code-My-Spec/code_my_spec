defmodule CodeMySpecSpex.Story127.Criterion5931Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5931 — Content edit produces a new fingerprint and triggers
  downstream consumers.

  Covers Rule "A relevant filesystem event triggers the full chain."
  When a tracked file's content changes and sync runs, the File
  projection shows a new fingerprint AND downstream consumers
  (FileComponentSync, validity derivation) re-run against the fresh
  content. The user-visible proof is: after editing a spec file's
  module name, the Files page shows the new fingerprint AND the spec
  row's component link points at the new module name.

  This builds on 5944 (which asserts fingerprint refresh only) by
  also asserting the consumer-side effect.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @spec_path ".code_my_spec/spec/example_context.spec.md"
  @impl_v1_path "lib/example_context.ex"
  @impl_v2_path "lib/renamed_context.ex"
  @spec_v2_path ".code_my_spec/spec/renamed_context.spec.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees a content edit ripple through fingerprint AND downstream consumers" do
    scenario "renaming a spec's module re-derives the component link after sync" do
      given_ "the agent has written v1 spec + impl and the engineer has synced",
             context do
        :ok = Environments.write_file(context.environment, @spec_path, spec_v1())
        :ok = Environments.write_file(context.environment, @impl_v1_path, impl_v1())

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "the v1 spec is showing its v1 fingerprint and ExampleContext component link",
             context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@spec_path}\"] [data-fingerprint=\"#{sha256(spec_v1())}\"]"
               )

        assert has_element?(
                 files_live,
                 "[data-file-path=\"#{@spec_path}\"] [data-test='file-component-link']",
                 "ExampleContext"
               )

        {:ok, context}
      end

      given_ "the agent has renamed the module in both spec and impl files",
             context do
        :ok = Environments.delete_file(context.environment, @spec_path)
        :ok = Environments.delete_file(context.environment, @impl_v1_path)
        :ok = Environments.write_file(context.environment, @spec_v2_path, spec_v2())
        :ok = Environments.write_file(context.environment, @impl_v2_path, impl_v2())
        {:ok, context}
      end

      when_ "the engineer re-syncs from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the renamed spec row carries a new fingerprint and the new component link",
            context do
        # Fingerprint side — proves classify+upsert observed the new bytes.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_v2_path}\"] [data-fingerprint=\"#{sha256(spec_v2())}\"]"
               )

        # Consumer side — FileComponentSync derived a component for the
        # NEW module name, proving the consumer re-ran on the edit.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_v2_path}\"] [data-test='file-component-link']",
                 "RenamedContext"
               )

        # Old artifacts no longer linger.
        refute has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"]"
               )

        {:ok, context}
      end
    end
  end

  defp spec_v1, do: spec_for("ExampleContext", "lib/example_context.ex")
  defp spec_v2, do: spec_for("RenamedContext", "lib/renamed_context.ex")

  defp spec_for(module, _path) do
    """
    # #{module}

    ## Type

    context

    A context demonstrating consumer re-run on content edit.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Dependencies

    - None

    ## Components

    ### #{module}.Inner

    Placeholder child module.
    """
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
