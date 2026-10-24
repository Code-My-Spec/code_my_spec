defmodule CodeMySpec.AppInstances.AppInstance do
  @moduledoc "One server-issued runtime identity for an app served from a source checkout."

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Encrypted.Binary
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo.References
  alias CodeMySpec.Devices.Device

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "app_instances" do
    belongs_to(:project, Project)
    belongs_to(:environment, CodeMySpec.Environments.Environment)
    belongs_to(:device, Device)
    field(:working_copy_id, :binary_id)
    field(:default, :boolean, default: true)
    field(:source_root, :string)
    field(:status, :string)
    field(:checked_at, :utc_datetime_usec)
    field(:url, :string)
    field(:commit, :string)
    field(:serving_commit, :string)
    field(:deployment_image, :string)
    field(:preview_status, :string)
    field(:preview_checked_at, :utc_datetime_usec)
    field(:preview_url, :string)
    field(:preview_tunnel_id, :string)
    field(:preview_tunnel_secret, Binary)
    field(:promotion_sync, :map, default: %{})
    field(:persistent, :boolean, default: false)
    field(:port_mode, Ecto.Enum, values: [configured: "configured", allocated: "allocated"])
    field(:database_mode, Ecto.Enum, values: [configured: "configured", clone: "clone"])
    field(:database_source, :string)
    field(:after_promote, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :id,
      :project_id,
      :environment_id,
      :device_id,
      :working_copy_id,
      :default,
      :source_root,
      :status,
      :checked_at,
      :url,
      :commit,
      :serving_commit,
      :deployment_image,
      :preview_status,
      :preview_checked_at,
      :preview_url,
      :preview_tunnel_id,
      :preview_tunnel_secret,
      :promotion_sync,
      :persistent,
      :port_mode,
      :database_mode,
      :database_source,
      :after_promote
    ])
    |> validate_required([:project_id, :port_mode, :database_mode])
    |> validate_inclusion(:status, [nil, "serving", "erroring", "down", "starting"])
    |> validate_inclusion(:preview_status, [nil, "serving", "erroring", "down"])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:environment_id)
    |> foreign_key_constraint(:device_id)
    |> foreign_key_constraint(:working_copy_id)
    |> References.check()
    |> unique_constraint(:default, name: :app_instances_one_default_per_source_index)
  end
end
