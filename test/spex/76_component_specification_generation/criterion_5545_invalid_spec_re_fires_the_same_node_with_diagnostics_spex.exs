defmodule CodeMySpecSpex.Story76.Criterion5545Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5545 — Invalid spec re-fires the same node with diagnostics.

  Surface: `start_task` MCP tool against a `spec_valid` requirement on a
  context Component whose spec file exists but fails validation. The
  re-fire prompt must surface the spec file path AND the validator's
  diagnostic feedback so the agent knows what to fix.

  Failing test until ContextSpec.command/2 (and its peers) inject prior
  validator diagnostics into the prompt on a re-fire. Per the design
  decision the prompt passes the spec path (not the file contents) plus
  the diagnostic text — the agent reads the file via the path.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  @spec_path ".code_my_spec/spec/example_context.spec.md"
  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Invalid spec re-fires the same node with diagnostics" do
      given_ "an ExampleContext Component is synced with an INVALID context spec on disk", context do
        env = context.environment

        invalid_spec = """
        # ExampleContext

        ## Type

        context

        (missing required Functions and Dependencies sections)
        """

        :ok = Environments.write_file(env, @spec_path, invalid_spec)
        :ok = Environments.write_file(env, @impl_path, "defmodule ExampleContext do\nend\n")

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

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

      when_ "the agent calls start_task for the spec_valid requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "spec_valid",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt names the spec file path so the agent can read the prior content", context do
        assert context.prompt =~ @spec_path,
               "expected the canonical spec path to appear so the agent can re-read its prior attempt"

        {:ok, context}
      end

      and_ "the prompt surfaces the validator diagnostics from the prior failure", context do
        assert context.prompt =~ ~r/Previous validation|Validator diagnostics|Diagnostics from prior run/i,
               "expected a heading that introduces the validator's diagnostic feedback on a re-fire"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
