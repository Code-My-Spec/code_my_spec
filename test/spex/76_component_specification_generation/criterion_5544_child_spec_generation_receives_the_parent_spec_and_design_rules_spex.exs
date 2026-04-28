defmodule CodeMySpecSpex.Story76.Criterion5544Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5544 — Child spec generation receives the parent spec and
  design rules.

  Surface: `start_task` MCP tool against a `spec_file` requirement on a
  child Component whose parent already has a valid spec on disk. The
  prompt the agent receives must reference the parent context's spec
  file path (so the agent can read the parent's design before writing
  the child) plus the design rules applicable to the child's type.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Child spec generation receives the parent spec and design rules" do
      given_ :synced_context_component

      given_ "a child Component exists under the synced parent", context do
        child =
          Fixtures.component_fixture(context.scope, %{
            type: "schema",
            module_name: "ExampleContext.User",
            name: "ExampleContext User",
            parent_component_id: context.component.id
          })

        {:ok, Map.put(context, :child, child)}
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

      when_ "the agent calls start_task for the child's spec_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.child.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt names the parent context's spec file path", context do
        assert context.prompt =~
                 "Parent Context Design File: .code_my_spec/spec/example_context.spec.md",
               "expected the prompt to reference the parent spec path so the agent can read it"

        {:ok, context}
      end

      and_ "the prompt carries the design rules section", context do
        assert context.prompt =~ "Design Rules:",
               "expected a Design Rules section so the agent doesn't speculate about applicable constraints"

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
