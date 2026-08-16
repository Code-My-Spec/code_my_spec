defmodule CodeMySpec.Repo.Migrations.AddS3EndpointToProjects do
  @moduledoc """
  The CLI's mirror of `projects.s3_endpoint` — see the server migration of the
  same name for why the column exists.

  Mirrored late, and the gap was not silent for long: `Project` declares the
  field, so every query loading a project against a CLI database failed with

      ** (Exqlite.Error) no such column: p0.s3_endpoint

  which is most of what the local app does. It went unnoticed only because the
  published binary predates the field and no CLI database had been migrated
  since — the next release would have shipped a schema its own database could
  not answer.

  Nullable, no default, exactly as on the server: null means Amazon, and the
  fallback lives on the schema.
  """
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :s3_endpoint, :string
    end
  end
end
