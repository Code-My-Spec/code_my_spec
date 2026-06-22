defmodule CodeMySpec.Mail.Mailbox do
  @moduledoc """
  A mailbox on a project's domain. Belongs to a project; either assigned to a
  user (`user_id`) or shared (`user_id` nil). At most one mailbox per project
  is the `catch_all`, receiving inbound addressed to no specific mailbox.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "mailboxes" do
    field :address, :string
    field :catch_all, :boolean, default: false

    belongs_to :project, CodeMySpec.Projects.Project, type: :binary_id
    belongs_to :user, CodeMySpec.Users.User, type: :id
    has_many :emails, CodeMySpec.Mail.Email

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(mailbox, attrs) do
    mailbox
    |> cast(attrs, [:address, :catch_all, :user_id, :project_id])
    |> validate_required([:address, :project_id])
    |> validate_format(:address, ~r/^[^@\s]+@[^@\s]+$/, message: "must be an email address")
    |> unique_constraint([:project_id, :address])
  end

  @doc "A mailbox with no assigned user is shared across the account."
  def shared?(%__MODULE__{user_id: nil}), do: true
  def shared?(%__MODULE__{}), do: false
end
