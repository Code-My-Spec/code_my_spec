defmodule CodeMySpec.Repo.Migrations.AppInstanceDeploymentImages do
  use Ecto.Migration

  def change do
    alter table(:app_instances) do
      add(:deployment_image, :text)
    end
  end
end
