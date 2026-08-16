defmodule CodeMySpecSpex.Story670.Criterion5584Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5584 — Only the matching component-type code rules appear.

  Surface: `start_task` MCP tool against the `implementation_file`
  requirement on a context Component, with three rule files planted
  in the project environment:

  - `context` + `code` — the only one that should surface
  - `live_view` + `code` — wrong component type
  - `context` + `test` — wrong session type

  The agent's prompt must carry the matching rule's content and
  leave the other two off so non-applicable rules don't dilute the
  agent's focus.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  @match_signature "Always group context functions by domain noun, never by verb."
  @wrong_type_signature "LiveViews must mount with a connected? guard."
  @wrong_session_signature "Tests must use describe blocks per public function."

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "Only the matching component-type code rules appear" do
      given_ "three rule files exist — one matching, one wrong type, one wrong session",
             context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/rules/context_code.md",
            rule_file("context", "code", @match_signature)
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/rules/liveview_code.md",
            rule_file("liveview", "code", @wrong_type_signature)
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/rules/context_test.md",
            rule_file("context", "test", @wrong_session_signature)
          )

        {:ok, context}
      end

      given_ :synced_context_component

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

      then_ "the matching context+code rule's content surfaces in the prompt", context do
        assert context.prompt =~ @match_signature,
               "expected the context+code rule body in the prompt, got:\n#{context.prompt}"

        {:ok, context}
      end

      and_ "the wrong-type rule body does not appear", context do
        refute context.prompt =~ @wrong_type_signature,
               "liveview+code rule must not surface for a context component"

        {:ok, context}
      end

      and_ "the wrong-session rule body does not appear", context do
        refute context.prompt =~ @wrong_session_signature,
               "context+test rule must not surface during a code session"

        {:ok, context}
      end
    end
  end

  defp rule_file(component_type, session_type, body) do
    """
    ---
    component_type: "#{component_type}"
    session_type: "#{session_type}"
    ---

    # Rule

    #{body}
    """
  end
end
