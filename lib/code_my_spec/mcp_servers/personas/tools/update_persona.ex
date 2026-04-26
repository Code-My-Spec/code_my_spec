defmodule CodeMySpec.McpServers.Personas.Tools.UpdatePersona do
  @moduledoc """
  Updates an existing persona's metadata (name, slug, headline, persona_type).
  Identifies the persona by id or slug. Research text on disk is unaffected —
  if you change the slug, move the `.code_my_spec/personas/<slug>/` folder
  yourself.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
    field :id, :string, doc: "UUID of the persona to update. Provide id or slug."
    field :slug, :string, doc: "Current slug of the persona. Provide id or slug."
    field :name, :string, doc: "New display name."
    field :new_slug, :string, doc: "New slug (URL-safe identifier). Optional."
    field :headline, :string, doc: "New headline."

    field :persona_type, :string,
      doc:
        "New evidence tier: 'proto', 'qualitative', or 'statistical'. Default stays unchanged when omitted."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, persona} <- fetch_persona(scope, params),
         attrs = build_attrs(params),
         {:ok, updated} <- Personas.update_persona(scope, persona, attrs) do
      {:reply, PersonasMapper.update_response(updated), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, PersonasMapper.validation_error(changeset), frame}

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

  defp build_attrs(params) do
    %{}
    |> maybe_put(:name, params[:name])
    |> maybe_put(:slug, params[:new_slug])
    |> maybe_put(:headline, params[:headline])
    |> maybe_put(:persona_type, params[:persona_type])
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, _key, ""), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end
