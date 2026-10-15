defmodule CodeMySpec.Personas.Tools.GetPersona do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Personas.Tools

  @impl true
  def name, do: "get_persona"

  @impl true
  def description do
    """
    Fetches a single persona by slug or persona_id from the active project.

    Use this to pull a full persona record when you need its DB metadata
    (headline, persona_type, timestamps) during the intake conversation.
    The research text lives on disk at `.code_my_spec/personas/<slug>/` —
    use the knowledge MCP to read those files.
    """
  end

  @impl true
  def params do
    %{
      slug:
        {:meta, :string,
         [description: "Persona slug (e.g., 'founder'). Provide either slug or persona_id."]},
      persona_id:
        {:meta, :string,
         [
           description:
             "Persona UUID. Provide either slug or persona_id. Slug wins if both are given."
         ]}
    }
  end

  # Slug first: the description promises it wins when both are given.
  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, persona} <- Tools.fetch_persona(scope, slug_first(params)) do
      {:ok, Tools.persona_text(persona, heading: "Persona")}
    else
      {:error, reason} -> Tools.error(reason)
    end
  end

  defp slug_first(%{slug: slug}) when is_binary(slug) and slug != "", do: %{slug: slug}
  defp slug_first(params), do: params
end
