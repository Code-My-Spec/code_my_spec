defmodule CodeMySpec.Repo.Migrations.CreateDeploys do
  use Ecto.Migration

  @moduledoc """
  A deploy is a row, not a markdown file.

  `deploy` used to be a requirement gated on `.code_my_spec/devops/deploys/
  story_<id>.md` containing the substring "verified", which the agent wrote for
  itself. It came out of the graph in d207ad38 for that reason. This is the
  other half of that decision: somewhere to record what actually happened, so
  the requirement can read observed state instead of prose.

  `health_verified_at` is separate from `inserted_at` on purpose. A deploy that
  shipped and never passed its health check is not a deploy that counts —
  criterion 1964 turns on exactly that distinction — so the column that decides
  the requirement is the one that can only be set by a check passing.
  """

  def change do
    create table(:deploys) do
      # `projects.id` is a uuid and `stories.id` is a bigint — they are not
      # consistent in this schema, so both are stated explicitly rather than
      # left to the default.
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :story_id, references(:stories, on_delete: :delete_all), null: false
      add :environment, :string, null: false

      # What actually went out, so "the running version is traceable to the
      # commit CI built" has something to compare against.
      add :commit_sha, :string
      add :version, :string

      # Null until a health check passed. See moduledoc.
      add :health_verified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One row per story per environment: a redeploy of the same story updates
    # rather than accumulating, so "is this story on UAT" has one answer.
    create unique_index(:deploys, [:story_id, :environment])
    create index(:deploys, [:project_id, :environment])
  end
end
