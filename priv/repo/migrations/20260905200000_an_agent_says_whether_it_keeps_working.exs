defmodule CodeMySpec.Repo.Migrations.AnAgentSaysWhetherItKeepsWorking do
  use Ecto.Migration

  @moduledoc """
  Continuous mode moves onto the agent, and stays on the session too.

  Story 538's R2, rewritten 2026-09-05: continuous is a mode on the agent, not a
  property of the work. It was a boolean on `sessions`, and a session is a Claude
  Code session keyed by `external_id` — it has no role. So "message the coding
  agent, keep its stop hook enforcing, and let it stop when coding work runs
  out" had nowhere to live: three agents on one working copy share no session,
  and a session with three agents could not put them in different modes.

  Both places, on John's call: *"I think we put it in both places. Pretty sure
  the session is becoming external agent only."* An agent we run carries its own
  mode here; an external agent keeps carrying it on its session until that
  distinction finishes settling. The stop hook resolves whichever identity it
  has.

  ## Default false, and it matters which way

  A mode that governs whether an agent keeps working itself has to be entered
  deliberately. Defaulting to true would put every agent ever started into a
  loop nobody asked for, including the ones staffed automatically when an epic
  is placed — which is the failure `tap_out` exists to escape and would arrive
  before anyone had a chance to want it.
  """

  def change do
    alter table(:agents) do
      add :continuous, :boolean, null: false, default: false
    end

    # Read on every stop an agent makes, and by the control that turns a whole
    # working copy on or off at once.
    create index(:agents, [:working_copy_id, :continuous])
  end
end
