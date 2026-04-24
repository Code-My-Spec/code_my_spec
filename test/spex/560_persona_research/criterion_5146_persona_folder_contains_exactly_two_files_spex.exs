defmodule CodeMySpecSpex.Story560.Criterion5146Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5146 — Persona folder contains exactly summary.md and sources.md.
  Observable: when both files exist with valid content for a linked persona,
  the checker passes and the graph advances.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent writes exactly summary.md and sources.md" do
    scenario "checker accepts the folder and graph advances" do
      given_ :persona_exists

      given_ "summary.md and sources.md both exist", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            "# Founder\n\n## Role\nSolo founder.\n\n## Goals\nShip.\n\n## Pain Points\nSwitching.\n\n## Context\nOne person.\n\n## Decision Drivers\nSpeed.\n\n## Evidence\nInternal notes.\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "- https://example.com — Source — 2026-04-23\n"
          )

        {:ok, context}
      end

      given_ :persona_research_task_started

      when_ "the agent fires the stop hook and asks for next work", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/stop", %{"session_id" => context.session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :next_response, response)}
      end

      then_ "personas_complete is cleared from the actionable set", context do
        body = response_text(context.next_response)

        refute body =~ "personas_complete",
               "expected personas_complete to clear when both files exist"

        :ok
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end

  defp response_text(other), do: inspect(other)
end
