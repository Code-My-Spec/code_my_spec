defmodule CodeMySpec.Repo.Migrations.StoriesPromotedBeforeQaStampsKeepTheirPublication do
  use Ecto.Migration

  # `promoted_qa_commit` arrived with no backfill, so every story promoted
  # before it read as unpromoted once its verdict began requiring the stamp
  # (174 stories on 2026-10-27). A story already stamped promoted keeps the
  # verdict it had: its current QA revision is the one that landing published.
  def up do
    execute("""
    UPDATE stories
    SET promoted_qa_commit = qa_ready_commit,
        promoted_candidate_commit = COALESCE(promoted_candidate_commit, qa_ready_commit)
    WHERE promoted_version IS NOT NULL
      AND promoted_qa_commit IS NULL
      AND qa_ready_commit IS NOT NULL
    """)
  end

  def down, do: :ok
end
