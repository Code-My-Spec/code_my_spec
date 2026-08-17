defmodule CodeMySpecSpex.Story76.Criterion5540Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5540 — Context spec lands at the canonical path.

  Surface: `start_task` MCP tool against a `spec_file` requirement on a
  context-typed Component that has no spec on disk.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Context spec lands at the canonical path" do
      given_ "a context Component exists with no spec file on disk", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story76.SpecPath",
            name: "Story76 Spec Path"
          )

        :ok = ComponentHelpers.delete_stub(context.scope, component)

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the spec_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "spec_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt directs the agent to write at the canonical spec path", context do
        assert context.prompt =~ "Please write the specification to:",
               "expected the prompt to instruct where to write the spec"

        assert context.prompt =~ ".code_my_spec/spec/story76/spec_path.spec.md",
               "expected the canonical spec path derived from the module name, got: #{context.prompt}"

        {:ok, context}
      end
    end
  end
end
