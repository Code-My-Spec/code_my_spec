defmodule CodeMySpecSpex.Story669.Criterion5570Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5570 — Component-type test rules surface in the Test Rules section.

  Surface: `start_task` MCP tool against a `test_file` requirement on a
  Component whose type has matching test rules planted in the project's
  `.code_my_spec/rules/` directory. The prompt the agent receives must
  carry those rules verbatim under a `Test Rules:` section so the agent
  doesn't speculate about applicable conventions.

  Rules in CodeMySpec are markdown files on disk with YAML frontmatter
  (`component_type` + `session_type`) — that is the production surface.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  @rule_signature "Group tests by describe blocks that match the function signature exactly."

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Component-type test rules surface in the Test Rules section" do
      given_ "a test rule for the context component type is in the project environment",
             context do
        rule_body = """
        ---
        component_type: "context"
        session_type: "test"
        ---

        # Context Test Rules

        #{@rule_signature}
        """

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/rules/context_test.md",
            rule_body
          )

        {:ok, context}
      end

      given_ "a context Component exists", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story669.RulesCtx",
            name: "Story669 RulesCtx"
          )

        {:ok, Map.put(context, :component, component)}
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

      when_ "the agent calls start_task for the test_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the prompt carries a Test Rules section", context do
        assert context.prompt =~ "Test Rules:",
               "expected a 'Test Rules:' heading in the prompt, got: #{context.prompt}"

        {:ok, context}
      end

      and_ "the prompt includes the matching rule's content", context do
        assert context.prompt =~ @rule_signature,
               "expected the on-disk rule body to surface in the prompt"

        {:ok, context}
      end
    end
  end
end
