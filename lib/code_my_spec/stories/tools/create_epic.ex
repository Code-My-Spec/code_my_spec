defmodule CodeMySpec.Stories.Tools.CreateEpic do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Epics
  alias CodeMySpec.Stories.Tools.Responses, as: StoriesMapper

  @impl true
  def name, do: "create_epic"

  @impl true
  def description do
    """
    Creates an epic — a named collection of user stories.

    Epics are **organizational only**. Putting a story in an epic does not
    release it for development; that is `ready_for_dev` on the story itself.
    Use `set_epic_stories_ready` to release a whole epic in one go.
    """
  end

  @impl true
  def params do
    %{
      name: {:required, {:meta, :string, [description: "Epic name (e.g., 'Gods and Religion')"]}},
      description: {:meta, :string, [description: "What this epic covers (optional)"]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, epic} <- Epics.create_epic(scope, params) do
      response =
        {:ok, "Epic created: \"#{epic.name}\" (ID: #{epic.id}, slug: #{epic.slug})"}

      response
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        StoriesMapper.validation_error(changeset)

      {:error, atom} ->
        StoriesMapper.error(atom)
    end
  end
end
