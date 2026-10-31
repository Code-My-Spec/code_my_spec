defmodule CodeMySpec.Repo.Migrations.AnOverlayNamesTheFilesItWasComputedFrom do
  @moduledoc """
  The digest of the scan a copy's overlay was computed from (paths and content
  fingerprints). A report is served only while the copy's File rows still
  digest to it: files that reached the server some other way, or a newer
  manifest, make it stale, and the verdicts are computed from the rows instead.
  Nil for a harness from before the digest, which is never served.
  """

  use Ecto.Migration

  def change do
    alter table(:copy_overlays) do
      add :files, :string
    end
  end
end
