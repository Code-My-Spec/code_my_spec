defmodule CodeMySpec.Repo.Migrations.AnEpicIsProposedAgreedToAndHandedOver do
  use Ecto.Migration

  @moduledoc """
  An epic gains a life: draft → proposed → dispatched.

  The two transitions are two different acts, which is the whole of story 964's
  approval gate. John: *"the agent sending it and the meatbags approving it are
  two different things."* The main agent moves an epic to `proposed`; a person
  moves it to `dispatched`.

  `working_copy_id` is where it went. Recorded rather than derived, because
  which copy an epic runs on is the agent's choice at the moment it dispatches —
  *"if an existing working copy and agent is appropriate it gets assigned there,
  or a fresh one at the agent's discretion"* — and re-deriving that later would
  answer with today's idle copy rather than the one the work is actually on.

  `failure_reason` is what to say when it went wrong. An agent that died and an
  agent that is thinking both produce nothing, so without somewhere to write the
  difference down "it is still going" is what gets reported about work that
  stopped hours ago.

  No default on the schema side of the boundary — `default: "draft"` here
  because the column is `null: false` and existing rows need a value, which is
  the one case a migration default earns its place.
  """

  def change do
    alter table(:epics) do
      add :status, :string, null: false, default: "draft"
      add :working_copy_id, :binary_id
      add :failure_reason, :text
      add :dispatched_at, :utc_datetime
    end

    # Read on every dispatch decision: "is anything in progress on this
    # project" is the question the assign-when-idle node asks.
    create index(:epics, [:project_id, :status])
  end
end
