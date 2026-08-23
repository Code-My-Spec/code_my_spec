defmodule CodeMySpecSpex.Story597.Criterion5287Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5287 — Bare project produces a minimal prompt without optional sections.

  When no specs and no index exist, the prompt omits the
  "Existing Integration Specs" and "Existing Index" sections — the
  bare-project entry-point experience.

  Surface: `start_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The prompt grounds itself in real project state" do
    scenario "Bare project produces a minimal prompt without optional sections" do
      given_ "no specs and no index exist", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)

        refute Fixtures.integration_spec_exists?(context.environment, "twilio"),
               "expected no integration specs in the bare-project fixture"

        refute Fixtures.integration_index_exists?(context.environment),
               "expected no integration index in the bare-project fixture"

        {:ok, context}
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

      when_ "the agent calls start_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "qa_integration_plan",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "a prompt came back at all", context do
        # Both assertions below refute a section header, and an errored or
        # empty reply contains neither — so "the optional sections are absent"
        # was true of a `start_task` that produced nothing. `StartTask` writes
        # the task id into a footer, so that is the cheapest evidence the
        # prompt is a prompt.
        assert extract_task_id!(context.prompt),
               "expected start_task to return a prompt with its task id, got:\n#{context.prompt}"

        {:ok, context}
      end

      then_ "the prompt does not contain an Existing Integration Specs section", context do
        refute context.prompt =~ "Existing Integration Specs",
               "expected the existing-specs section to be absent"

        {:ok, context}
      end

      and_ "the prompt does not contain an Existing Index section", context do
        refute context.prompt =~ "## Existing Index",
               "expected the existing-index section to be absent"

        {:ok, context}
      end
    end
  end
end
