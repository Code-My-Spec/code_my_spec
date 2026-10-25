defmodule CodeMySpec.Stories.Tools.DependencySummary do
  @moduledoc false

  alias CodeMySpec.Requirements
  alias CodeMySpec.Stories

  def render(scope, story) do
    links = Stories.list_story_dependencies(scope, story.id)

    section(scope, "Builds on", links.builds_on) <>
      section(scope, "Built on by", links.built_on_by)
  end

  defp section(scope, heading, stories) do
    rows = Enum.map_join(stories, "\n", &row(scope, &1))
    "\n\n**#{heading}:**\n" <> if(rows == "", do: "None", else: rows)
  end

  defp row(scope, story) do
    "- Story #{story.number}: #{story.title} (#{status(scope, story)})"
  end

  defp status(_scope, %{retired_at: at}) when not is_nil(at), do: "retired"
  defp status(_scope, %{ready_for_dev: ready}) when ready != true, do: "parked"

  defp status(scope, story) do
    scope =
      if story.working_copy_id,
        do: %{scope | active_working_copy_id: story.working_copy_id},
        else: scope

    {nodes, _at} = Requirements.cached_all(scope)
    owned = Enum.filter(nodes, &(&1.entity_type == "story" and &1.entity_id == story.id))

    cond do
      owned == [] -> "not started"
      Enum.all?(owned, & &1.satisfied) -> "complete"
      Enum.any?(owned, & &1.satisfied) -> "in progress"
      true -> "not started"
    end
  end
end
