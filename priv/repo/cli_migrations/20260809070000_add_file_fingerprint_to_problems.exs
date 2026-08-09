defmodule CodeMySpec.Repo.Migrations.AddFileFingerprintToProblems do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `add_file_fingerprint_to_problems`.

  Same purpose: record which version of a file a problem was found in, so a
  finding that outlived its file can be recognised as superseded. See the
  Postgres copy for the observation that prompted it.
  """

  def change do
    alter table(:problems) do
      add :file_fingerprint, :string
    end
  end
end
