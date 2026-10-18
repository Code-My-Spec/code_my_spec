defmodule CodeMySpec.Agents.Tools.ReadyStoriesWithoutEpic do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Tools.EpicsResponses, as: EpicsMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "ready_stories_without_epic"

  @impl true
  def description do
    """
    Ready stories that belong to no epic.

    The reading that lets you answer "which ready story is outside every epic" —
    which nothing else exposes. `list_epics` lists epics and `assign_story_to_epic`
    writes one; neither says which stories are in none of them.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case orphans(context) do
      {:ok, stories} -> EpicsMapper.orphans(stories)
      {:error, reason} -> EpicsMapper.error(reason)
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, stories} <- orphans(context) do
      {:ok, Enum.map(stories, &%{"number" => &1.number, "title" => &1.title})}
    end
  end

  # One query for both paths. A second implementation for scripts is a second
  # thing to keep true, and the script path is the one story 1058's criteria
  # drive.
  defp orphans(context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      {:ok, Stories.ready_stories_without_epic(scope)}
    end
  end
end
