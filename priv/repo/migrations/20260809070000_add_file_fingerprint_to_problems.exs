defmodule CodeMySpec.Repo.Migrations.AddFileFingerprintToProblems do
  use Ecto.Migration

  @moduledoc """
  Which version of a file a problem was found in.

  A problem outlives the file it describes. Reconciles replace problems per
  source per file, so a finding survives whenever the replacing run does not
  re-examine that exact path — and it is then reported against a file that has
  since changed underneath it. Observed: a credo finding reported at line 86 of
  a file that is 83 lines long, presented as a current result rather than a
  stale one, with the analyzer's own tool run by hand disagreeing.

  Stamping the file's fingerprint at reconcile makes that detectable without
  the server needing the disk, which it does not have. A problem whose
  fingerprint differs from the file's current one describes a version that no
  longer exists.

  Nullable: problems recorded before this, and problems about no particular
  file, have nothing to compare. Those are kept rather than dropped — the
  filter only removes a finding it can *prove* is superseded, because hiding a
  real finding is worse than showing an old one.
  """

  def change do
    alter table(:problems) do
      add :file_fingerprint, :string
    end
  end
end
