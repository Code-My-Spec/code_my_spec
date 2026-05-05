defmodule CodeMySpecSpex.Story669.Criterion5568Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5568 — Invalid test file holds the node and re-fires next
  pass with diagnostics.

  Surface: stop hook persists a compile error against the test file →
  test_spec_alignment becomes unsatisfied → the next `start_task` for
  the same component re-fires `ComponentTest.command/2`, which injects
  the prior validator diagnostics into the prompt so the agent knows
  what to fix.

  Setup goes through real surfaces: `:synced_context_component` plants
  the parent + impl, then an inline `given_` writes a test file that
  doesn't match the spec's Test Assertions and re-syncs. The sync
  pipeline's `validate_test_alignment` flips File.valid to false on
  the misaligned test file, which makes `test_spec_alignment` an
  unsatisfied requirement on the next graph pass — exactly the
  re-fire condition the diagnostics injection is meant for.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  @spec_path ".code_my_spec/spec/example_context.spec.md"
  @impl_path "lib/example_context.ex"
  @test_file "test/example_context_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Invalid test file holds the node and re-fires next pass with diagnostics" do
      given_ "a context component is synced with a misaligned test file", context do
        env = context.environment

        :ok = Environments.write_file(env, @spec_path, spec_with_test_assertions())
        :ok = Environments.write_file(env, @impl_path, "defmodule ExampleContext do\n  @moduledoc false\nend\n")

        # Empty test module — has no `test "returns :ok when called"`,
        # so `FileSync.validate_test_alignment/3` will flip File.valid
        # to false and `test_spec_alignment` will land unsatisfied.
        :ok =
          Environments.write_file(
            env,
            @test_file,
            """
            defmodule ExampleContextTest do
              use ExUnit.Case
            end
            """
          )

        # First sync creates the component from the spec file. Files
        # are validated against the components-list snapshot taken
        # *before* the component exists, so test_spec_alignment lands
        # vacuously valid on this pass.
        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        # Second sync re-validates files against the now-existing
        # component, so `validate_test_alignment/3` sees the misaligned
        # test and marks File.valid = false.
        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        component = Fixtures.get_component_by_module_name(context.scope, "ExampleContext")
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

      when_ "the agent re-fires start_task on the test_spec_alignment requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_spec_alignment",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the start_task prompt surfaces prior validation diagnostics", context do
        assert context.prompt =~ "Previous validation diagnostics",
               "expected the re-fire prompt to carry a 'Previous validation diagnostics' section, got: #{context.prompt}"

        {:ok, context}
      end

      and_ "the diagnostics reference the offending test file", context do
        assert context.prompt =~ @test_file,
               "expected the diagnostics to name the offending test file, got: #{context.prompt}"

        {:ok, context}
      end
    end
  end

  defp spec_with_test_assertions do
    """
    # ExampleContext

    ## Type

    context

    An example context for BDD specs.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Test Assertions

    - returns :ok when called

    ## Dependencies

    - None

    ## Components

    ### ExampleContext.Noop

    Placeholder child module.
    """
  end
end
