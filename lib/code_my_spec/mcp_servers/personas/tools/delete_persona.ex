defmodule CodeMySpec.McpServers.Personas.Tools.DeletePersona do
  @moduledoc """
  Deletes a project-scoped persona, including every row in `persona_stories`
  that links it to a story. Identifies the persona by id or slug. Files under
  `.code_my_spec/personas/<slug>/` are NOT removed — clean those up manually
  if needed.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
    field :id, :string, doc: "UUID of the persona to delete. Provide id or slug."
    field :slug, :string, doc: "Slug of the persona to delete. Provide id or slug."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, persona} <- fetch_persona(scope, params),
         {:ok, deleted} <- Personas.delete_persona(scope, persona) do
      {:reply, PersonasMapper.delete_response(deleted), frame}
    else
      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end

  defp fetch_persona(scope, %{id: id}) when is_binary(id) and id != "" do
    case Personas.get_persona(scope, id) do
      nil -> {:error, :not_found}
      persona -> {:ok, persona}
    end
  end

  defp fetch_persona(scope, %{slug: slug}) when is_binary(slug) and slug != "" do
    case Personas.get_persona_by_slug(scope, slug) do
      nil -> {:error, :not_found}
      persona -> {:ok, persona}
    end
  end

  defp fetch_persona(_scope, _params), do: {:error, "must provide id or slug"}
end
