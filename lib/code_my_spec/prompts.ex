defmodule CodeMySpec.Prompts do
  @moduledoc """
  Prompt formatting for agent consumption.

  Handles the assembly of orchestration prompts — parent instructions
  plus child checklists with API URLs.
  """

  @doc """
  Builds an orchestration prompt for a scope: :children requirement.

  Combines the parent's command text with a checklist of children,
  where each uncompleted child links to its API endpoint for
  individual instructions.

  ## Parameters

  - `parent_text` — the parent task module's command output
  - `checklist` — list of `%{id, name, satisfied, detail}` maps from the checker
  - `base_url` — API base for child endpoints (e.g., `/api/projects/my-project/requirements/project_setup`)
  """
  def build_children_prompt(parent_text, checklist, base_url) do
    done = Enum.count(checklist, &(&1[:satisfied] || &1["satisfied"]))
    total = length(checklist)

    items =
      Enum.map_join(checklist, "\n", fn item ->
        name = item[:name] || item["name"]
        id = item[:id] || item["id"]
        satisfied = item[:satisfied] || item["satisfied"]

        if satisfied do
          "- [x] #{name}"
        else
          "- [ ] #{name} — `GET #{base_url}/#{id}`"
        end
      end)

    """
    #{String.trim(parent_text)}

    ## Steps (#{done}/#{total})

    #{items}

    Work through each unchecked step. Fetch instructions from the linked
    endpoint and follow them. When all steps are complete, stop the session.
    """
  end
end
