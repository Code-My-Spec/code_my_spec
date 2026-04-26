defmodule CodeMySpecSpex.Story80.Criterion5271Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5271 — Retrofit developer's customized phoenix.md survives the auto-write pass.

  The retrofit persona: a developer adopting CodeMySpec on a Phoenix
  app that already has its own ADRs. Hand-written rationale on a
  standard-stack topic must survive the auto-write pass so the team's
  historical context isn't erased.

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

  spex "Pre-existing ADR files are never overwritten" do
    scenario "Retrofit developer's customized phoenix.md survives the auto-write pass" do
      given_ "phoenix.md already exists with the team's retrofit rationale", context do
        Fixtures.with_custom_adr(
          context.environment,
          "phoenix",
          "We chose Phoenix because of internal expertise on the platform team"
        )

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

      then_ "phoenix.md still contains the retrofit rationale", context do
        content = Fixtures.read_adr(context.environment, "phoenix")

        assert is_binary(content), "expected phoenix.md to still exist"

        assert content =~ "We chose Phoenix because of internal expertise on the platform team",
               "expected hand-written phoenix.md content to survive the auto-write pass"

        :ok
      end
    end
  end
end
