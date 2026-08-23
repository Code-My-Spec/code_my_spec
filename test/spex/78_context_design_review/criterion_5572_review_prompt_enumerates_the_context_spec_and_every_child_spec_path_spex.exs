defmodule CodeMySpecSpex.Story78.Criterion5572Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5572 — Review prompt enumerates the context spec and every
  child spec path.

  Surface: `start_task` MCP tool against a `review_file` requirement on a
  context Component. The prompt the agent receives must list the context
  spec path and every child component's spec path so the reviewer reads
  the full unit, not just the parent.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Review prompt enumerates the context spec and every child spec path" do
      given_ :synced_context_component

      given_ "a child Component exists under the synced parent", context do
        child =
          ComponentHelpers.create(context.scope,
            type: "schema",
            module_name: "ExampleContext.Item",
            name: "ExampleContext Item",
            parent_component_id: context.component.id
          )

        {:ok, Map.put(context, :child, child)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the review_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "review_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt names the context spec path", context do
        assert context.prompt =~ ".code_my_spec/spec/example_context.spec.md",
               "expected the parent context spec path so the reviewer reads the parent first"

        {:ok, context}
      end

      and_ "the prompt names every child component's spec path", context do
        assert context.prompt =~ ".code_my_spec/spec/example_context/item.spec.md",
               "expected the child spec path so the reviewer reads the full unit, not just the parent"

        {:ok, context}
      end
    end
  end
end
