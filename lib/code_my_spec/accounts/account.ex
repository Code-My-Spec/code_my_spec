defmodule CodeMySpec.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t(),
          slug: String.t() | nil,
          type: :personal | :team,
          members: [CodeMySpec.Accounts.Member.t()] | Ecto.Association.NotLoaded.t(),
          users: [CodeMySpec.Users.User.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @reserved_slugs ~w(admin api www help support docs blog)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "accounts" do
    field :name, :string
    field :slug, :string
    field :type, Ecto.Enum, values: [:personal, :team], default: :personal

    has_many :members, CodeMySpec.Accounts.Member, on_delete: :delete_all
    has_many :users, through: [:members, :user]

    timestamps()
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :slug, :type])
    |> validate_required([:name, :type])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_slug()
    |> unique_constraint(:slug)
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> maybe_generate_slug()
  end

  defp validate_slug(changeset) do
    changeset
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "must contain only lowercase letters, numbers, and hyphens"
    )
    |> validate_length(:slug, min: 3, max: 50)
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved and cannot be used")
    |> validate_team_slug_format()
  end

  defp validate_team_slug_format(changeset) do
    case get_field(changeset, :type) do
      :team ->
        validate_format(changeset, :slug, ~r/^[a-z]/,
          message: "must start with a letter for team accounts"
        )

      _ ->
        changeset
    end
  end

  defp maybe_generate_slug(changeset) do
    with :personal <- get_field(changeset, :type),
         nil <- get_field(changeset, :slug),
         name when is_binary(name) <- get_field(changeset, :name) do
      put_change(changeset, :slug, generate_slug(name))
    else
      _ -> changeset
    end
  end

  defp generate_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
