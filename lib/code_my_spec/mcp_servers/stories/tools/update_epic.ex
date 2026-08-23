defmodule CodeMySpec.McpServers.Stories.Tools.UpdateEpic do
  @moduledoc """
  Renames an epic or rewrites what it says it covers.

  An epic's description is where the decisions that hold across its stories
  live — the shared rules, the things each story has to answer. That is exactly
  the text that goes stale first, because deciding to drop a story is a decision
  *about* the epic, and until now the only way to correct it was to build a
  second epic beside the first and move everything into it.

  Renaming keeps the slug the epic already had. A slug that moves breaks every
  link anybody saved to it, and a name is a label rather than an identity.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Epics
  alias CodeMySpec.McpServers.Stories.StoriesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :epic_name, :string, required: true, doc: "Current epic name or slug"
    field :name, :string, doc: "New name (optional)"
    field :description, :string, doc: "New description (optional)"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, epic} <- fetch(scope, params.epic_name),
         {:ok, updated} <- Epics.update_epic(scope, epic, attrs(params)) do
      response =
        Response.tool()
        |> Response.text(
          "Epic updated: \"#{updated.name}\" (ID: #{updated.id}, slug: #{updated.slug})"
        )

      {:reply, response, frame}
    else
      {:error, :not_found} ->
        {:reply, StoriesMapper.error(:not_found), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, StoriesMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, StoriesMapper.error(atom), frame}
    end
  end

  # By name or by slug, because callers have both: `list_epics` prints the slug
  # and `assign_story_to_epic` takes the name.
  defp fetch(scope, name_or_slug) do
    case Epics.get_epic_by_name(scope, name_or_slug) ||
           Epics.get_epic_by_slug(scope, name_or_slug) do
      nil -> {:error, :not_found}
      epic -> {:ok, epic}
    end
  end

  # Only what was actually passed. A nil description is "leave it alone", not
  # "clear it" — an update tool that blanks the field you did not mention is one
  # that loses the text it exists to protect.
  defp attrs(params) do
    params
    |> Map.take([:name, :description])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
