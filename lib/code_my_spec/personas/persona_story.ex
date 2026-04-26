defmodule CodeMySpec.Personas.PersonaStory do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Stories.Story

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          persona_id: Ecto.UUID.t() | nil,
          story_id: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "persona_stories" do
    belongs_to :persona, Persona, type: :binary_id
    belongs_to :story, Story

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(persona_story, attrs) do
    persona_story
    |> cast(attrs, [:persona_id, :story_id])
    |> validate_required([:persona_id, :story_id])
    |> unique_constraint([:persona_id, :story_id])
    |> assoc_constraint(:persona)
    |> assoc_constraint(:story)
  end
end
