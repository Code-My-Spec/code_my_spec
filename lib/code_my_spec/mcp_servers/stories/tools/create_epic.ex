defmodule CodeMySpec.McpServers.Stories.Tools.CreateEpic do
  @moduledoc """
  Creates an epic — a named collection of user stories.

  Epics are **organizational only**. Putting a story in an epic does not
  release it for development; that is `ready_for_dev` on the story itself.
  Use `set_epic_stories_ready` to release a whole epic in one go.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :name, :string, required: true, doc: "Epic name (e.g., 'Gods and Religion')"
    field :description, :string, doc: "What this epic covers (optional)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, epic} <- Epics.create_epic(scope, params) do
      response =
        Response.tool()
        |> Response.text("Epic created: \"#{epic.name}\" (ID: #{epic.id}, slug: #{epic.slug})")

      {:reply, response, frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end
end
