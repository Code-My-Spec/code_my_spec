defmodule CodeMySpecSpex.Story598.Criterion5294Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5294 — Retrofit project with phx.gen.auth already applied checks off auth and lists the rest as pending.

  When phx.gen.auth's detection file is present, the prompt marks
  phx.gen.auth as already run and lists the remaining standard
  generators as pending.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Generators run in dependency order with detection-based skipping" do
    scenario "Retrofit project with phx.gen.auth already applied checks off auth and lists the rest as pending" do
      given_ "the baseline project exists with phx.gen.auth's detection file in place",
             context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        Fixtures.with_generator_applied(context.environment, "phx_gen_auth")

        assert Fixtures.generator_applied?(context.environment, "phx_gen_auth"),
               "expected phx_gen_auth detection file to be present"

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

      then_ "phx.gen.auth is marked as already run", context do
        assert context.prompt =~ "[x] `mix phx.gen.auth Users User users --live` — already run",
               "expected phx.gen.auth to be checked off"

        {:ok, context}
      end

      and_ "the remaining standard generators are still pending", context do
        for cmd <- [
              "mix cms_gen.accounts",
              "mix cms_gen.integrations",
              "mix cms_gen.support_widget"
            ] do
          assert context.prompt =~ "[ ] `#{cmd}`",
                 "expected #{cmd} to remain pending"
        end

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
