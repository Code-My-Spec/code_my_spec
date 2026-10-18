defmodule CodeMySpec.Stories.Tools.SetEpicStoriesReady do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Epics
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "set_epic_stories_ready"

  @impl true
  def description do
    """
    Releases (or parks) every story currently in an epic, in one shot.

    This is a **bulk edit of the stories**, not a property of the epic. Stories
    added to the epic afterwards are unaffected and stay parked — the epic
    carries no readiness of its own and nothing cascades later.
    """
  end

  @impl true
  def params do
    %{
      epic_name: {:required, {:meta, :string, [description: "Epic whose stories to stamp"]}},
      ready_for_dev:
        {:required,
         {:meta, :boolean,
          [
            description: "true to release the epic's stories for development, false to park them"
          ]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, epic} <- fetch_epic(scope, params.epic_name),
         {:ok, count} <- Epics.set_epic_stories_ready(scope, epic, params.ready_for_dev) do
      verb = if params.ready_for_dev, do: "released for development", else: "parked"

      response =
        {:ok,
         "#{count} #{noun(count)} in epic \"#{epic.name}\" #{verb}. " <>
           "Stories added to this epic later are unaffected."}

      response
    else
      {:error, atom} -> StoriesMapper.error(atom)
    end
  end

  defp fetch_epic(scope, name) do
    case Epics.get_epic_by_name(scope, name) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  defp noun(1), do: "story"
  defp noun(_), do: "stories"
end
