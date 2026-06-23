defmodule CodeMySpec.Repo.Migrations.AddContentPublishingToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :content_source_path, :string
      add :image_bucket, :string
      add :images_host, :string
      add :content_bucket, :string
    end
  end
end
