defmodule CodeMySpecSpex.Story76.Criterion5542Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5542 — live_context Components instantiate the live-context graph.

  Surface: `start_task` MCP tool against a `spec_file` requirement on a
  live_context-typed Component. The task module the graph stamps must be
  `AgentTasks.LiveContextSpec`, observable via the unique opening line of
  the prompt that module emits.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "live_context Components instantiate the live-context graph" do
      given_ "a live_context Component exists with no spec file on disk", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "live_context",
            module_name: "Story76Web.SpecLive",
            name: "Story76Web SpecLive"
          )

        :ok = ComponentHelpers.delete_stub(context.scope, component)

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

      then_ "the prompt is the LiveContextSpec template", context do
        assert context.prompt =~
                 "Your task is to generate a specification for a Phoenix live context",
               "expected the LiveContextSpec template's opening line — the live_context type must select that module via satisfied_by"

        {:ok, context}
      end

      and_ "the canonical live-context spec path is referenced", context do
        assert context.prompt =~ ".code_my_spec/spec/story76_web/spec_live.spec.md",
               "expected the canonical live-context spec path; got: #{context.prompt}"

        {:ok, context}
      end
    end
  end
end
