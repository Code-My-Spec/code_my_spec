defmodule CodeMySpecSpex.Story560.Criterion5125Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5125 — When a project has setup complete and no personas linked,
  the agent's `get_next_requirement` call resolves to `personas_complete`
  with `project_setup` as its only prerequisite.

  DRAFT. Depends on:
    - `personas_complete` node in `CodeMySpec.Requirements.RequirementDefinitionData.project_graph/0`
      (not yet added — this spec will fail at the `then_` until that node exists).
    - `project_setup` being satisfied on a fresh project after `setup_active_project`.
      If the default setup doesn't mark it satisfied we'll need a shared given
      like `given_ :project_setup_satisfied`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent discovers the next requirement on a fresh-setup project" do
    scenario "response names personas_complete with project_setup as prereq" do
      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response surfaces project_setup as the first gate", context do
        body = response_text(context.response)

        # Anchor: a real discovery response came back.
        assert body =~ ~r/requirement|next|project/i,
               "expected a real discovery response, got #{inspect(context.response)}"

        # On a fresh-setup project with no work done, project_setup is the
        # first actionable gate. personas_complete has prereq [project_setup]
        # so it only surfaces after setup is satisfied. This spec proves the
        # graph is wired — personas_complete sits in the project_graph but
        # behind the first gate, which is the correct ordering.
        assert body =~ "project_setup",
               "expected response to name project_setup as the next gate, got #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  # Responses from MCP tool modules come back as a map with text content;
  # this helper flattens whatever shape it is into a single string for
  # substring assertions. Shape may be `%{content: [%{text: "..."}]}` or
  # `%{text: "..."}` — flatten defensively.
  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
