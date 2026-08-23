defmodule CodeMySpecSpex.Story670.Criterion5585Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5585 — No matching rules leaves the rules section empty
  rather than padded.

  Surface: `start_task` MCP tool against the `implementation_file`
  requirement on a context Component, with rule files planted for
  unrelated component types and unrelated session kinds. None
  match — so the prompt's rules block is rendered without any rule
  content, and no unrelated rule body sneaks in just to fill the
  space.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  @wrong_type_signature "LiveViews must mount with a connected? guard."
  @wrong_session_signature "Tests must use describe blocks per public function."

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation" do
    scenario "No matching rules leaves the rules section empty rather than padded" do
      given_ "only non-matching rule files exist (wrong type, wrong session)", context do
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
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
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

      then_ "a prompt came back at all", context do
        # The contrast the refutes need: an errored or empty reply contains no
        # section header either, so "the optional section is absent" held for a
        # `start_task` that produced nothing. `StartTask` writes the task id
        # into a footer, so that is the cheapest evidence a prompt is a prompt.
        assert extract_task_id!(context.prompt),
               "expected start_task to return a prompt with its task id, got:\n#{context.prompt}"

        {:ok, context}
      end

      then_ "neither non-matching rule body appears in the prompt", context do
        refute context.prompt =~ @wrong_type_signature,
               "liveview+code rule must not surface for a context component"

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
