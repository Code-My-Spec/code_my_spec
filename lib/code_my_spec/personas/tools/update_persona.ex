defmodule CodeMySpec.Personas.Tools.UpdatePersona do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Tools

  @impl true
  def name, do: "update_persona"

  @impl true
  def description do
    """
    Updates an existing persona's metadata (name, slug, headline, persona_type).
    Identifies the persona by persona_id or slug. Research text on disk is unaffected —
    if you change the slug, move the `.code_my_spec/personas/<slug>/` folder
    yourself.
    """
  end

  @impl true
  def params do
    %{
      persona_id:
        {:meta, :string,
         [description: "UUID of the persona to update. Provide persona_id or slug."]},
      slug:
        {:meta, :string,
         [description: "Current slug of the persona. Provide persona_id or slug."]},
      name: {:meta, :string, [description: "New display name."]},
      new_slug: {:meta, :string, [description: "New slug (URL-safe identifier). Optional."]},
      headline: {:meta, :string, [description: "New headline."]},
      persona_type:
        {:meta, :string,
         [
           description:
             "New evidence tier: 'proto', 'qualitative', or 'statistical'. Default stays unchanged when omitted."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- Tools.scope(context),
         {:ok, persona} <- fetch(scope, params),
         {:ok, updated} <- Personas.update_persona(scope, persona, attrs(params)) do
      {:ok, Tools.update_text(updated)}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end

  defp fetch(scope, params) do
    case Tools.fetch_persona(scope, params) do
      {:error, :missing_identifier} -> {:error, "must provide persona_id or slug"}
      result -> result
    end
  end

  defp attrs(params) do
    %{}
    |> put_given(:name, params[:name])
    |> put_given(:slug, params[:new_slug])
    |> put_given(:headline, params[:headline])
    |> put_given(:persona_type, params[:persona_type])
  end

  defp put_given(attrs, _key, nil), do: attrs
  defp put_given(attrs, _key, ""), do: attrs
  defp put_given(attrs, key, value), do: Map.put(attrs, key, value)
end
