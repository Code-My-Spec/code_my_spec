defmodule CodeMySpecSpex.Story127.Criterion5920Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5920 — Full sync rescans every tracked file in the project.

  Covers Rule "Disk is the source of truth; the DB is a projection of it."
  When the engineer triggers a sync, every file in the project's tracked
  roots (`lib/`, `test/`, `.code_my_spec/`) is read, classified, and
  upserted into the Files projection — independent of which roots a file
  happens to live in.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"
  @spec_path ".code_my_spec/spec/example_context.spec.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees every tracked file appear in the projection after a full sync" do
    scenario "files in lib/, test/, and .code_my_spec/ all materialize in the Files table" do
      given_ "the agent has written files spanning all three tracked roots",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, impl_content())
        :ok = Environments.write_file(context.environment, @test_path, test_content())
        :ok = Environments.write_file(context.environment, @spec_path, spec_content())
        {:ok, context}
      end

      when_ "the engineer triggers a sync from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "each file appears in the projection with its role classified",
            context do
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_path}\"]"
               )

        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@test_path}\"]"
               )

        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"]"
               )

        # Classification ran across all three roots — spec is the
        # distinguishing role, proving sync didn't just dump generic rows.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"] [data-test='file-role']",
                 "spec"
               )

        {:ok, context}
      end
    end
  end

  defp impl_content do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end

  defp test_content do
    """
    defmodule ExampleContextTest do
      use ExUnit.Case, async: true
    end
    """
  end

  defp spec_content do
    """
    # ExampleContext

    ## Type

    context

    A context demonstrating full-sync coverage across tracked roots.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Dependencies

    - None

    ## Components

    ### ExampleContext.Inner

    Placeholder child module.
    """
  end
end
