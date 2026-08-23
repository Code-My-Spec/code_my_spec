defmodule CodeMySpecSpex.Story598.Criterion5293Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5293 — Bootstrap developer's prompt lists every standard generator as pending, in order.

  With no detection files on disk, the prompt lists every standard
  generator (phx.gen.auth, cms_gen.accounts, cms_gen.integrations,
  cms_gen.support_widget) as pending, in dependency order.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Generators run in dependency order with detection-based skipping" do
    scenario "Bootstrap developer's prompt lists every standard generator as pending, in order" do
      given_ "the project has a baseline mix.exs and no generator detection files",
             context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
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

      when_ "the agent calls start_task for the code_generation task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "code_generation",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the status section signals that no generators have been run yet", context do
        assert context.prompt =~ ~r/no generators (have )?(been )?run/i,
               "expected the no-generators-run marker in the status section"

        {:ok, context}
      end

      and_ "the pending instruction list names every standard generator command", context do
        for cmd <- [
              "mix phx.gen.auth Users User users --live",
              "mix cms_gen.accounts",
              "mix cms_gen.integrations",
              "mix cms_gen.support_widget"
            ] do
          assert context.prompt =~ "`#{cmd}`",
                 "expected #{cmd} to appear in the pending generator list"
        end

        {:ok, context}
      end

      and_ "generators appear in dependency order", context do
        assert context.prompt =~
                 ~r/mix phx\.gen\.auth.*mix cms_gen\.accounts.*mix cms_gen\.integrations.*mix cms_gen\.support_widget/s,
               "expected the prompt to list generators in dependency order"

        {:ok, context}
      end
    end
  end
end
