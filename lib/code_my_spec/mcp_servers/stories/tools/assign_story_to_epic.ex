defmodule CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic do
  @moduledoc """
  Moves a story into an epic.

  A story belongs to at most one epic, so this is a move rather than an add —
  the story leaves whatever epic it was in. Omit `epic_name` to remove the
  story from its epic entirely.

  Assignment does not change readiness.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story_id, :string, required: true, doc: "Story to move"

    field :epic_name, :string,
      doc: "Destination epic name. Omit to remove the story from its epic."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, story} <- fetch_story(scope, params.story_id),
         {:ok, epic} <- fetch_epic(scope, params[:epic_name]),
         {:ok, _story} <- Epics.assign_story(scope, story, epic) do
      {:reply, render(story, epic), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  defp fetch_story(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> {:error, :not_found}
      story -> {:ok, story}
    end
  end

  defp fetch_epic(_scope, nil), do: {:ok, nil}
  defp fetch_epic(_scope, ""), do: {:ok, nil}

  defp fetch_epic(scope, name) do
    case Epics.get_epic_by_name(scope, name) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  defp render(story, nil) do
    Response.tool()
    |> Response.text("Story \"#{story.title}\" (ID: #{story.id}) removed from its epic.")
  end

  defp render(story, epic) do
    Response.tool()
    |> Response.text(~s[Story "#{story.title}" (ID: #{story.id}) moved into epic "#{epic.name}".])
  end
end
