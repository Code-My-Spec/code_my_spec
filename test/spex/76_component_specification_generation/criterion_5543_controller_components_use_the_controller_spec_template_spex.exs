defmodule CodeMySpecSpex.Story76.Criterion5543Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5543 — Controller Components use the controller spec template.

  Surface: `start_task` MCP tool against a `spec_file` requirement on a
  controller-typed Component. The graph must instantiate a controller-
  specific spec template (not the default ComponentSpec template) — the
  prompt's opening line is the observable signature of which template
  fired.

  Failing test until `controller_graph` and `AgentTasks.ControllerSpec`
  land in the codebase.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Controller Components use the controller spec template" do
      given_ "a controller Component exists with no spec file on disk", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "controller",
            module_name: "Story76Web.UsersController",
            name: "Story76Web UsersController"
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

      then_ "the prompt is the ControllerSpec template", context do
        assert context.prompt =~
                 "Your task is to generate a specification for a Phoenix controller",
               "expected the ControllerSpec template's opening line — the controller type must select that module via satisfied_by"

        {:ok, context}
      end

      and_ "the canonical controller spec path is referenced", context do
        assert context.prompt =~ ".code_my_spec/spec/story76_web/users_controller.spec.md",
               "expected the canonical controller spec path; got: #{context.prompt}"

        {:ok, context}
      end
    end
  end
end
