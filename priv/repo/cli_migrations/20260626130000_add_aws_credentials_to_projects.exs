defmodule CodeMySpec.Repo.Migrations.AddAwsCredentialsToProjects do
  use Ecto.Migration

  @moduledoc """
  The local CLI is the content publisher and signs S3 uploads with the user's
  own AWS keys. A published install has no `envs/.env`, so the keys live on the
  project — encrypted at rest via Cloak (`CodeMySpec.Encrypted.Binary` → binary
  column). Region is not secret, so it stays plain text.
  """

  def change do
    alter table(:projects) do
      add :aws_access_key_id, :binary
      add :aws_secret_access_key, :binary
      add :aws_region, :string
    end
  end
end
