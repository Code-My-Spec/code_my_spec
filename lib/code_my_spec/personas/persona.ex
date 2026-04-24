defmodule CodeMySpec.Personas.Persona do
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Stories.Story

  @type persona_type :: :proto | :qualitative | :statistical

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          slug: String.t() | nil,
          name: String.t() | nil,
          headline: String.t() | nil,
          persona_type: persona_type() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t(),
          stories: [Story.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @persona_types [:proto, :qualitative, :statistical]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "personas" do
    field :slug, :string
    field :name, :string
    field :headline, :string
    field :persona_type, Ecto.Enum, values: @persona_types, default: :proto

    belongs_to :account, Account, type: :binary_id
    many_to_many :stories, Story, join_through: PersonaStory

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of valid persona types."
  @spec persona_types() :: [persona_type()]
  def persona_types, do: @persona_types

  @doc false
  def changeset(persona, attrs) do
    persona
    |> cast(attrs, [:account_id, :slug, :name, :headline, :persona_type])
    |> validate_required([:account_id, :slug, :name])
    |> validate_length(:slug, min: 1, max: 64)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:headline, max: 255)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "must be lowercase alphanumeric with underscores or hyphens"
    )
    |> unique_constraint([:account_id, :slug])
    |> assoc_constraint(:account)
  end
end
