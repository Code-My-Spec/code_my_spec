defmodule CodeMySpec.Repo.Migrations.APromotionNamesAStoryOrAnIssue do
  use Ecto.Migration

  # A queued promotion is for a story or an issue fix, or for neither (a main
  # copy's restart, or unattributed work): `subject_type` + `subject_id`
  # replace `story_number`, and stay nullable for that third case.
  #
  # An issue records the commit its fix landed at, so it resolves only once its
  # fix is on main and its QA has passed.
  def change do
    alter table(:promotion_queue_entries) do
      add :subject_type, :string
      add :subject_id, :string
      remove :story_number, :integer
    end

    alter table(:issues) do
      add :landed_commit, :string
    end
  end
end
