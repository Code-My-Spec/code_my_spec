defmodule CodeMySpecWeb.PersonasJSON do
  alias CodeMySpec.Personas.Persona

  def index(%{personas: personas}) do
    %{data: Enum.map(personas, &data/1)}
  end

  def show(%{persona: persona}) do
    %{data: data(persona)}
  end

  defp data(%Persona{} = persona) do
    %{
      id: persona.id,
      slug: persona.slug,
      name: persona.name,
      headline: persona.headline,
      persona_type: persona.persona_type,
      account_id: persona.account_id,
      inserted_at: persona.inserted_at,
      updated_at: persona.updated_at
    }
  end
end
