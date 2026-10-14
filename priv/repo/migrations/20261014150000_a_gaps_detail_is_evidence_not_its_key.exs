defmodule CodeMySpec.Repo.Migrations.AGapsDetailIsEvidenceNotItsKey do
  use Ecto.Migration

  @moduledoc """
  Issue bb784152 (and its duplicates 1a41b25f, 2f67ccdf): `capability_gaps` was
  unique on `(project_id, role, capability)`, and `capability` was whatever free
  prose `answer_notification`'s `worked_around` carried. The same underlying gap
  worded three different ways by the main agent became three different rows,
  each reporting "1 times" -- so the same defect was filed three times, and the
  one real recurrence signal (`occurrences`) never had a chance to count past 1
  for any of them.

  `capability` stays the dedupe key, but it is now meant to hold a short, stable
  identifier (a tool name, normalized) rather than a sentence. The sentence --
  the detail that varies every time -- moves to this new column, carried as
  evidence on the row and in the issue description, rather than as part of what
  decides whether two occurrences are the same gap.
  """

  def change do
    alter table(:capability_gaps) do
      add :detail, :text
    end
  end
end
