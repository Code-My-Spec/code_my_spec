defmodule CodeMySpec.Repo.Migrations.AddQaReadyToStories do
  use Ecto.Migration

  # The ready-for-QA stamp: the commit a story's working copy was certified at
  # (clean tree, all four analyzers clean at that commit, the story's own spex
  # green), and when. Nullable with no default — unset means not ready.
  def change do
    alter table(:stories) do
      add :qa_ready_commit, :string
      add :qa_ready_at, :utc_datetime_usec
    end
  end
end
