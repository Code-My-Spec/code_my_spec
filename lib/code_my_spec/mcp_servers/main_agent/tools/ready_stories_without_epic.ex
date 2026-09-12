defmodule CodeMySpec.McpServers.MainAgent.Tools.ReadyStoriesWithoutEpic do
  @moduledoc """
  Ready stories that belong to no epic.

  The reading that lets you answer "which ready story is outside every epic" —
  which nothing else exposes. `list_epics` lists epics and `assign_story_to_epic`
  writes one; neither says which stories are in none of them.
  """

  # Why this is the main agent's and not product's
  #
  # Story 1058's observed failure was a *product* agent hitting this wall, so
  # putting the tool in `@product` is the obvious fix and is a different story:
  # criterion 3329 says the main agent covering a gap files an issue proposing
  # exactly that, and somebody decides it.
  #
  # What this story is about is the main agent being able to answer at all,
  # whatever the roles happen to carry today. If the tool later moves into
  # `@product`, 3313 keeps working with a different capability in its place —
  # the criterion is about reach, not about epics.

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.McpServers.MainAgent.EpicsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case orphans(frame) do
      {:ok, stories} -> {:reply, EpicsMapper.orphans(stories), frame}
      {:error, reason} -> {:reply, EpicsMapper.error(reason), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(_params, frame) do
    with {:ok, stories} <- orphans(frame) do
      {:ok, Enum.map(stories, &%{"id" => &1.id, "title" => &1.title})}
    end
  end

  # One query for both paths. A second implementation for scripts is a second
  # thing to keep true, and the script path is the one story 1058's criteria
  # drive.
  defp orphans(frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      {:ok, Stories.ready_stories_without_epic(scope)}
    end
  end
end
