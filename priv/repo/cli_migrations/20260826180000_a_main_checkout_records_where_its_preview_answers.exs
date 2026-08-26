defmodule CodeMySpec.Repo.Migrations.AMainCheckoutRecordsWhereItsPreviewAnswers do
  use Ecto.Migration

  @moduledoc """
  Where a project's running preview answers.

  On the working copy rather than on the project, because the preview runs where
  the project runs — the designated main checkout, which is the same thing the
  timeline header and epic dispatch already key on. A column on `projects` would
  say a project has one address while nothing recorded which machine serves it.

  Nullable, and expected to be null on most rows. Every worktree can run the app
  and only one of them is the project's, so a preview address on a sibling
  checkout would be a second answer to a question with one.

  Written down rather than held in the harness, so a restart does not lose it
  and nobody has to onboard a checkout again to get it back.
  """

  def change do
    alter table(:working_copies) do
      add :preview_url, :string
    end
  end
end
