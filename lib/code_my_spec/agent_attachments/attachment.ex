defmodule CodeMySpec.AgentAttachments.Attachment do
  @moduledoc "An agent's revocable access to a working copy, independent of its runtime home."
  use Ecto.Schema
  import Ecto.Changeset
  alias CodeMySpec.Repo.References

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "agent_working_copy_attachments" do
    field :agent_id, Ecto.UUID
    field :working_copy_id, Ecto.UUID
    field :project_id, Ecto.UUID
    field :account_id, Ecto.UUID
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:id, :agent_id, :working_copy_id, :project_id, :account_id])
    |> validate_required([:id, :agent_id, :working_copy_id, :project_id, :account_id])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:working_copy_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:account_id)
    |> References.check()
    |> unique_constraint([:agent_id, :working_copy_id])
  end
end
