defmodule CodeMySpec.ClientUsers.ClientUser do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "client_users" do
    field :email, :string
    field :oauth_token, CodeMySpec.Encrypted.Binary
    field :oauth_refresh_token, CodeMySpec.Encrypted.Binary
    field :oauth_expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(client_user, attrs) do
    client_user
    |> cast(attrs, [:id, :email, :oauth_token, :oauth_refresh_token, :oauth_expires_at])
    |> validate_required([:id, :email])
    |> unique_constraint(:email)
  end
end
