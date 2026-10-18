defmodule CodeMySpec.Stories.Tools.StartThreeAmigosSession do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.AgentTasks.ThreeAmigos
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "start_three_amigos_session"

  @impl true
  def description do
    """
    Starts a Three Amigos / Example Mapping session on a single story.

    Returns the protocol prompt the agent uses to drive the workshop with
    the PM — persona linkage, rules (blue cards), scenarios (green cards),
    and questions (red cards). Delegates prompt building to
    `CodeMySpec.AgentTasks.ThreeAmigos`.
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         story when not is_nil(story) <- Stories.get_story_by_number(scope, params.story_number),
         {:ok, prompt} <-
           ThreeAmigos.command(scope, %{entity_type: :story, entity_id: to_string(story.id)}) do
      StoriesMapper.prompt_response(prompt)
    else
      nil ->
        StoriesMapper.not_found_error()

      {:error, reason} ->
        StoriesMapper.error(reason)
    end
  end
end
