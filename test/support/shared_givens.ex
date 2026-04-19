defmodule CodeMySpecSpex.SharedGivens do
  @moduledoc """
  Shared given steps for BDD specifications.

  Import into a spec:

      defmodule CodeMySpecSpex.SomeSpex do
        use CodeMySpecSpex.Case
        import_givens CodeMySpecSpex.SharedGivens

        spex "..." do
          scenario "..." do
            given_ :synced_context_component
            given_ :story_linked_to_component
            given_ :on_configuration_page
            # ...
          end
        end
      end

  Each given ESTABLISHES state and produces keys on `context` for subsequent
  steps. Givens do not assert — assertions about system behavior belong in
  `then_` steps. If setup fails it should surface as a pattern match failure
  or a raise at the point of failure, not as a separate assert.

  ## Defined givens

  - `:synced_context_component` — writes a context spec file into the
    in-memory environment, triggers sync via the /sync LiveView button,
    pattern-matches the resulting component. Produces `context.component`.
  - `:story_linked_to_component` — creates an unlinked story (arrives from
    server sync in production), then links it to `context.component` via
    `Stories.set_story_component`. Produces `context.story`. Requires
    `context.component` from a prior given.
  - `:on_configuration_page` — navigates to the project configuration
    LiveView. Produces `context.config_live`.

  Add new shared givens only after a third spec duplicates setup.
  """

  use SexySpex.Givens

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  @component_module_name "ExampleContext"
  @spec_path ".code_my_spec/spec/example_context.spec.md"
  @impl_path "lib/example_context.ex"

  # Writes a context spec file into the in-memory environment, triggers the
  # real sync pipeline via the /sync LiveView button, and fetches the
  # component that sync derived.
  given :synced_context_component do
    scope = context.scope
    env = context.environment

    :ok = Environments.write_file(env, @spec_path, spec_file_content())
    :ok = Environments.write_file(env, @impl_path, impl_file_content())

    {:ok, sync_live, _html} =
      live(context.conn, "/projects/#{context.project.name}/sync")

    sync_live
    |> element("button[phx-click='sync']")
    |> render_click()

    %_{} =
      component =
      Fixtures.get_component_by_module_name(scope, @component_module_name)

    {:ok, %{component: component}}
  end

  # Creates an unlinked story (matches production flow — stories arrive from
  # server sync with no component_id), then links it to the component via
  # the real linkage API.
  given :story_linked_to_component do
    scope = context.scope
    component = context.component

    story =
      Fixtures.story_fixture(scope,
        title: "Example user story",
        description: "An example for BDD specs"
      )

    {:ok, linked_story} = Fixtures.set_story_component(scope, story, component.id)

    {:ok, %{story: linked_story}}
  end

  # The engineer has opened the project configuration page.
  given :on_configuration_page do
    {:ok, config_live, _html} =
      live(context.conn, "/projects/#{context.project.name}/configuration")

    {:ok, %{config_live: config_live}}
  end

  # -- Content helpers --

  defp spec_file_content do
    """
    # ExampleContext

    An example context for BDD specs.

    ## Type

    context
    """
  end

  defp impl_file_content do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end
end
