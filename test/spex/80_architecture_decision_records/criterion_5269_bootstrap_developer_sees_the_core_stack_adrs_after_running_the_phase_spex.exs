defmodule CodeMySpecSpex.Story80.Criterion5269Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5269 — Bootstrap developer sees the core stack ADRs after running the phase.

  A fresh project ends up with elixir/phoenix/liveview/tailwind/daisyui
  ADRs on disk after `start_task` runs against `technical_strategy`.

  Surface: `start_task` MCP tool against the `technical_strategy`
  requirement.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Pre-made decisions are auto-written before the prompt" do
    scenario "Bootstrap developer sees the core stack ADRs after running the phase" do
      given_ "the project has no decision files on disk", context do
        Fixtures.reset_setup_env(context.environment)

        refute Fixtures.adr_exists?(context.environment, "elixir")
        refute Fixtures.adr_exists?(context.environment, "phoenix")

        {:ok, context}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the technical_strategy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, context}
      end

      then_ "each core stack ADR exists on disk", context do
        env = context.environment

        for topic <- ~w(elixir phoenix liveview tailwind daisyui) do
          assert Fixtures.adr_exists?(env, topic),
                 "expected ADR for #{topic} to exist after start_task"
        end

        :ok
      end
    end
  end
end
