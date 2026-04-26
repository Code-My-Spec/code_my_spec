defmodule CodeMySpec.ContentAdmin.ContentAdmin do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Accounts.Account

  @type t :: %__MODULE__{
          id: integer() | nil,
          raw_content: String.t() | nil,
          processed_content: String.t() | nil,
          parse_status: :success | :error | nil,
          parse_errors: map() | nil,
          metadata: map() | nil,
          project_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          account: Account.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "content_admin" do
    field :raw_content, :string
    field :processed_content, :string
    field :parse_status, Ecto.Enum, values: [:success, :error]
    field :parse_errors, :map
    field :metadata, :map

    belongs_to :project, Project, type: :binary_id
    belongs_to :account, Account, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(content_admin, attrs) do
    content_admin
    |> cast(attrs, [
      :raw_content,
      :processed_content,
      :parse_status,
      :parse_errors,
      :metadata,
      :project_id,
      :account_id
    ])
    |> validate_required([:raw_content, :parse_status, :project_id, :account_id])
  end
end
