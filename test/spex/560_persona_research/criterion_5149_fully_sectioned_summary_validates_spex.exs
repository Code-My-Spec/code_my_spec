defmodule CodeMySpecSpex.Story560.Criterion5149Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5149 — Fully-sectioned summary validates. When summary.md has
  all six required sections (Role, Goals, Pain Points, Context, Decision
  Drivers, Evidence) plus correct structure, the checker passes and the
  graph advances past personas_complete.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent writes a valid summary with all required sections" do
    scenario "graph clears personas_complete after stop hook" do
      given_ :persona_exists

      given_ "summary.md has all six required sections", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            """
            # Founder

            ## Role
            Solo founder.

            ## Goals
            Ship without hiring.

            ## Pain Points
            Context switching.

            ## Context
            Small team.

            ## Decision Drivers
            Speed and autonomy.

            ## Evidence
            Internal notes.
            """
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

      then_ "personas_complete is no longer in the response", context do
        body = response_text(context.next_response)

        refute body =~ "personas_complete",
               "expected personas_complete to clear with a fully-sectioned summary"

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
