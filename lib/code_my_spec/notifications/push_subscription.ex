defmodule CodeMySpec.Notifications.PushSubscription do
  @moduledoc """
  Schema for browser push notification subscriptions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh_key, :string
    field :auth_key, :string

    belongs_to :user, CodeMySpec.Users.User, type: :id

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :endpoint, :p256dh_key, :auth_key])
    |> validate_required([:user_id, :endpoint, :p256dh_key, :auth_key])
    |> unique_constraint(:endpoint)
  end
end
