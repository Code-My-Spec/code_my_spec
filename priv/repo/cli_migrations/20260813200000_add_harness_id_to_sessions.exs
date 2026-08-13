defmodule CodeMySpec.Repo.Migrations.AddHarnessIdToSessions do
  @moduledoc """
  Which working copy a Claude session is running in.

  Sessions were project-scoped only, and a project has as many sessions at once
  as it has checkouts being worked in. So nothing could answer "which session is
  running in *this* working copy" — which is the question a recorded model turn
  has to ask, because the turn arrives addressed to a harness and needs a
  session to belong to.

  Without it every turn fell back to the literal string "sprite" and every agent
  on the machine appended into one conversation per project, interleaved.

  The data was already arriving: the relay sends `X-Harness-Id`, the scope
  carries it, and `session_start` receives that scope alongside Claude's own
  session id in the same call. There was simply nowhere to put it.

  Nullable, and no default. A session created outside a harness — a mix task, a
  test, the cloud — genuinely has no working copy, and a default would invent
  one. `nil` reads as "not a checkout", which is true.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end

    # The lookup this exists for: newest session on a working copy.
    create index(:sessions, [:harness_id, :inserted_at])
  end
end
