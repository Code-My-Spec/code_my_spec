defmodule CodeMySpec.Repo.Migrations.ProblemsDropFileFingerprint do
  use Ecto.Migration

  # A finding is retired by the next run of its analyzer replacing the
  # source's set, not by its file's fingerprint moving (28d72f8a). The
  # query-time filter that read this column is gone.
  def up do
    alter table(:problems) do
      remove :file_fingerprint
    end
  end

  def down do
    alter table(:problems) do
      add :file_fingerprint, :string
    end
  end
end
