defmodule CodeMySpecSpex.Story560.Criterion5125Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5125 — When a project has setup complete and no personas linked,
  the agent's `get_next_requirement` call resolves to `personas_complete`.

  It used to resolve to `project_setup`, which gated it. Setup is no longer a
  requirement — `cms new` covers it, and the mainline exits the generator with
  it complete — so `personas_complete` has no prerequisites and is the root of
  the project graph. The criterion's own name is now literal: the response
  names personas_complete, not the gate in front of it.
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

      then_ "the response surfaces personas_complete as the first gate", context do
        body = response_text(context.response)

        # Anchor: a real discovery response came back.
        assert body =~ ~r/requirement|next|project/i,
               "expected a real discovery response, got #{inspect(context.response)}"

        # personas_complete is the root of the project graph, so on a project
        # with no work done it is the first actionable requirement.
        assert body =~ "personas_complete",
               "expected response to name personas_complete as the next gate, got #{inspect(context.response)}"

        refute body =~ "project_setup",
               "setup left the graph; offering it is offering work a generated " <>
                 "project does not have"

        {:ok, context}
      end
    end
  end

  # Responses from MCP tool modules come back as a map with text content;
  # this helper flattens whatever shape it is into a single string for
  # substring assertions. Shape may be `%{content: [%{text: "..."}]}` or
  # `%{text: "..."}` — flatten defensively.
end
