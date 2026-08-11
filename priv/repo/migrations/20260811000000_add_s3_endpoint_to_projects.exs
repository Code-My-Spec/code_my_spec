defmodule CodeMySpec.Repo.Migrations.AddS3EndpointToProjects do
  @moduledoc """
  Where a project's S3 credentials point.

  A project carries its own `aws_access_key_id` / `aws_secret_access_key`, and
  nothing said which host to sign them against — so ExAws sent every publish to
  Amazon. A customer on Hetzner object storage could paste a perfectly valid
  key pair into the Content settings and watch it fail with `NoSuchBucket` on a
  bucket they had definitely created, just not at Amazon.

  That is the whole of provisioning's own storage: the server step, the
  registry, backups and the object-storage step all use Hetzner. Content
  publishing was the one path that assumed otherwise.

  Nullable, and no default here — a null means Amazon, which is what every
  existing project is already doing. The schema is where the fallback lives.
  """
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :s3_endpoint, :string
    end
  end
end
