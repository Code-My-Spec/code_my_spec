defmodule CodeMySpecSpex.Story670.Criterion5583Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5583 — Component without a description still produces a
  labeled prompt.

  Surface: write a context spec with no description prose, drive
  `/sync` to land the component with `description == nil`, then drive
  `start_task` for the `implementation_file` requirement. The prompt
  must still render the literal `"No description provided"` so the
  agent isn't shown a blank or missing description line.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @module_name "ExampleNoDescription"
  @spec_path ".code_my_spec/spec/example_no_description.spec.md"
  @impl_path "lib/example_no_description.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "Component without a description still produces a labeled prompt" do
      given_ "a context Component is synced from a spec with no description prose", context do
        env = context.environment

        :ok = Environments.write_file(env, @spec_path, spec_file_content_without_description())
        :ok = Environments.write_file(env, @impl_path, impl_file_content())

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        # Pattern match raises if sync ever starts deriving a description
        # from this kind of spec — keeps the precondition honest without
        # turning the given_ into a behavior assertion.
        %{description: nil} =
          component =
          Fixtures.get_component_by_module_name(context.scope, @module_name)

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the implementation_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the prompt renders the No description provided fallback", context do
        assert context.prompt =~ "No description provided",
               "expected the description slot to render the fallback string, got: #{context.prompt}"

        {:ok, context}
      end
    end
  end

  defp spec_file_content_without_description do
    """
    # ExampleNoDescription

    ## Type

    context

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Dependencies

    - None

    ## Components
    """
  end

  defp impl_file_content do
    """
    defmodule ExampleNoDescription do
      @moduledoc false
    end
    """
  end
end
