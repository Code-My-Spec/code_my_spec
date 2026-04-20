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
  - `:bdd_task_started` — drives the real session_start hook + StartTask
    MCP tool to create an active `WriteBddSpecs` task on a story.
    Produces `context.session_id`. Requires `context.story` from
    `:story_linked_to_component`.
  - `:credo_available` — plants `deps/credo` under `context.scope.cwd`
    so the Credo analyzer's availability check passes. Pair with a
    cassette that replays `mix credo` output.

  Add new shared givens only after a third spec duplicates setup.
  """

  use SexySpex.Givens

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
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

  # Plants an empty `deps/credo` directory inside the stub working
  # directory so `CodeMySpec.StaticAnalysis.Analyzers.Credo.available?/1`
  # returns true for this spec. Without this, credo is unavailable in
  # the memfs-backed spec environment and the pipeline silently
  # no-ops credo. Pair with a cassette that replays the actual
  # `mix credo` output.
  given :credo_available do
    File.mkdir_p!(Path.join([context.scope.cwd, "deps", "credo"]))
    {:ok, %{}}
  end

  # The agent has signalled SessionStart and called the start_task MCP tool
  # for the "bdd_specs_exist" requirement on `context.story`. This is the
  # real contract the harness drives — we post to the same HTTP hook and
  # invoke the same MCP tool module, so the pipeline sees a real active
  # `WriteBddSpecs` task whose `analyzers/0` returns `[:spex_stale]`.
  given :bdd_task_started do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, _response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "bdd_specs_exist",
          entity_type: "story",
          entity_id: to_string(context.story.id),
          session_id: session_id
        },
        frame
      )

    {:ok, %{session_id: session_id}}
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
