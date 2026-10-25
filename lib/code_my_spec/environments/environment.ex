defmodule CodeMySpec.Environments.Environment do
  @moduledoc """
  A durable destination for a project's app instances.

  Harness-managed destinations represent development and other runtimes hosted
  by a connected device. Provisioned destinations retain provider/server and
  deployment metadata. Neither is an execution context or a working copy.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Repo.References

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          name: String.t(),
          management: :harness | :provisioned,
          host: String.t() | nil,
          server_name: String.t() | nil,
          ip: String.t() | nil,
          device_id: Ecto.UUID.t() | nil,
          first_deployed_at: DateTime.t() | nil
        }

  schema "environments" do
    field :management, Ecto.Enum, values: [:harness, :provisioned], default: :provisioned
    field :name, :string
    field :host, :string
    field :server_name, :string
    field :ip, :string
    field :first_deployed_at, :utc_datetime_usec

    belongs_to :project, CodeMySpec.Projects.Project
    belongs_to :device, CodeMySpec.Devices.Device

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [:name, :host, :server_name, :ip, :project_id, :device_id, :management])
    |> validate_required([:name, :project_id, :management])
    |> immutable_management()
    # The same constraint the server name, the DNS label and the sops filename
    # each impose separately. Validating it once here means a bad name is
    # refused where it is created rather than three steps later, as a provider
    # rejecting something that reads like our bug.
    |> validate_format(:name, ~r/^[a-z][a-z0-9-]{0,30}$/,
      message: "must be lowercase letters, digits and dashes, starting with a letter"
    )
    |> unique_constraint([:project_id, :name])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:device_id)
    |> References.check()
  end

  defp immutable_management(%{data: %{id: nil}} = changeset), do: changeset

  defp immutable_management(changeset) do
    if changed?(changeset, :management),
      do: add_error(changeset, :management, "cannot be changed after creation"),
      else: changeset
  end
end
