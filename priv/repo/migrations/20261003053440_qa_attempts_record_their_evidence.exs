defmodule CodeMySpec.Repo.Migrations.QaAttemptsRecordTheirEvidence do
  use Ecto.Migration

  @moduledoc """
  Story 1089. QA evidence (screenshots, recordings) moves to object storage;
  each upload's name, S3 key, content type and byte count land on the
  attempt that produced it.

  Nullable, not `null: false` like `scenarios` — this is genuinely optional
  (a `partial`/`fail` attempt, a pass with no screenshots on disk, a local
  dev run with no S3 bucket configured all leave it unset), the same
  reasoning `tools_used` on this table already settled on: nil means
  "nothing uploaded," not an empty list standing in for one Ecto's own
  change-tracking would otherwise have to be forced to write.
  """

  def change do
    alter table(:qa_attempts) do
      add :evidence, {:array, :map}
    end
  end
end
