defmodule CodeMySpec.Personas.Tools.DeletePersona do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Tools

  @impl true
  def name, do: "delete_persona"

  @impl true
  def description do
    """
    Deletes a project-scoped persona, including every row in `persona_stories`
    that links it to a story. Identifies the persona by persona_id or slug. Files under
    `.code_my_spec/personas/<slug>/` are NOT removed — clean those up manually
    if needed.
    """
  end

  @impl true
  def params do
    %{
      persona_id:
        {:meta, :string,
         [description: "UUID of the persona to delete. Provide persona_id or slug."]},
      slug:
        {:meta, :string,
         [description: "Slug of the persona to delete. Provide persona_id or slug."]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, persona} <- fetch(scope, params),
         {:ok, deleted} <- Personas.delete_persona(scope, persona) do
      {:ok, Tools.delete_text(deleted)}
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
end
