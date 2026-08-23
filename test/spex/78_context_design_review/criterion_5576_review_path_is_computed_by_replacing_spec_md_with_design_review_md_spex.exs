defmodule CodeMySpecSpex.Story78.Criterion5576Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5576 — Review path is computed by replacing
  `.spec.md` with `/design_review.md`.

  Surface: `start_task` MCP tool against a `review_file` requirement on a
  context Component. The prompt the agent receives must instruct the
  reviewer to write to a canonical path derived from the context spec
  path — never a path the agent picks.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Review path is computed by replacing .spec.md with /design_review.md" do
      given_ :synced_context_component

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

      then_ "the prompt directs the agent to write at the canonical review path", context do
        assert context.prompt =~ ".code_my_spec/spec/example_context/design_review.md",
               "expected the canonical review path derived by replacing .spec.md with /design_review.md"

        {:ok, context}
      end
    end
  end
end
