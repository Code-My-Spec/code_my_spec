defmodule CodeMySpec.Repo.Migrations.AppInstancesFollowDeviceDeletion do
  use Ecto.Migration

  def up, do: change_device_reference(:delete_all)
  def down, do: change_device_reference(:nilify_all)

  defp change_device_reference(on_delete) do
    drop(constraint(:app_instances, "app_instances_device_id_fkey"))

    alter table(:app_instances) do
      modify(:device_id, references(:devices, type: :binary_id, on_delete: on_delete))
    end
  end
end
