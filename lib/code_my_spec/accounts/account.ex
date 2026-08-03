defmodule CodeMySpec.Accounts.Account do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t(),
          slug: String.t() | nil,
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

    # The tiers. `:light` is the harness someone runs on their own machine;
    # `:pro` is our agent on our infrastructure.
    #
    # `:paid` predates the tiers and is still persisted in dev and prod. It is
    # kept as a valid value rather than renamed or backfilled: deciding what an
    # existing paid account becomes is a product question, and nobody has to
    # answer it to start charging. The gating story has to settle it before
    # anything branches on plan.
    field :plan, Ecto.Enum, values: [:free, :light, :pro, :paid], default: :free

    # One Stripe Customer per account, reused forever.
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string

    has_many :members, CodeMySpec.Accounts.Member, on_delete: :delete_all
    has_many :users, through: [:members, :user]

    timestamps()
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :slug, :plan, :stripe_customer_id, :stripe_subscription_id])
    |> validate_required([:name])
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
  end

  defp maybe_generate_slug(changeset) do
    with nil <- get_field(changeset, :slug),
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
