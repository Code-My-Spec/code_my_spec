defmodule CodeMySpecSpex.Story127.Criterion5924Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5924 — Saving a spec file flows through classify, validate,
  upsert, and component derivation.

  Covers Rule "A relevant filesystem event triggers the full chain."
  The chain's user-observable result is: a tracked File row whose role
  is `spec` AND a derived component link visible in /files.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @spec_path ".code_my_spec/spec/foo_context.spec.md"
  @impl_path "lib/foo_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees a saved spec materialize as a tracked file linked to a derived component" do
    scenario "spec gets classified, validated, and tied to a component" do
      given_ "the agent has written a context spec and a matching impl into the project",
             context do
        :ok = Environments.write_file(context.environment, @spec_path, spec_content())
        :ok = Environments.write_file(context.environment, @impl_path, impl_content())
        {:ok, context}
      end

      when_ "the engineer triggers a sync from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the spec file row carries role spec and a component link to FooContext",
            context do
        # Classified as :spec → role cell shows "spec"
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"] [data-test='file-role']",
                 "spec"
               )

        # Upserted + component derivation hooked up the owning component
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"] [data-test='file-component-link']",
                 "FooContext"
               )

        # Validation succeeded → validity badge says valid
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@spec_path}\"] [data-validity='valid']"
               )

        {:ok, context}
      end
    end
  end

  defp spec_content do
    """
    # FooContext

    ## Type

    context

    A context demonstrating the full sync chain.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Dependencies

    - None

    ## Components

    ### FooContext.Inner

    Placeholder child module.
    """
  end

  defp impl_content do
    """
    defmodule FooContext do
      @moduledoc false
    end
    """
  end
end
