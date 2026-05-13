defmodule CodeMySpec.McpServers.Personas.Tools.GetPersona do
  @moduledoc """
  Fetches a single persona by slug or id from the active project.

  Use this to pull a full persona record when you need its DB metadata
  (headline, persona_type, timestamps) during the intake conversation.
  The research text lives on disk at `.code_my_spec/personas/<slug>/` —
  use the knowledge MCP to read those files.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
    field :slug, :string,
      doc: "Persona slug (e.g., 'founder'). Provide either slug or id."

    field :id, :string,
      doc: "Persona UUID. Provide either slug or id. Slug wins if both are given."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, persona} <- resolve_persona(scope, params) do
      {:reply, PersonasMapper.persona_response(persona), frame}
    else
      {:error, :not_found} ->
        {:reply, PersonasMapper.error(:not_found), frame}

      {:error, :missing_identifier} ->
        {:reply, PersonasMapper.error("must provide either 'slug' or 'id'"), frame}

      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end

  defp resolve_persona(scope, %{slug: slug}) when is_binary(slug) and slug != "" do
    case Personas.get_persona_by_slug(scope, slug) do
      nil -> {:error, :not_found}
      persona -> {:ok, persona}
    end
  end

  defp resolve_persona(scope, %{id: id}) when is_binary(id) and id != "" do
    case Personas.get_persona(scope, id) do
      nil -> {:error, :not_found}
      persona -> {:ok, persona}
    end
  end

  defp resolve_persona(_scope, _params), do: {:error, :missing_identifier}
end
