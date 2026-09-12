defmodule CodeMySpec.Repo.Migrations.AMachineReportsWhatItIsCarrying do
  @moduledoc """
  What the box an agent runs on is carrying, and a correction to how a restart
  is judged to have worked.

  ## `devices.load`

  Story 1057, criterion 3324. A harness reports its preview, its tools and its
  head commit — facts it observes about itself — and never what it is running
  on. So agents on a saturated machine look individually slow, and the remedy
  for that reading puts more work on the machine: it is the one fault here whose
  wrong diagnosis deepens the fault.

  On the device rather than the working copy, because the box is what is
  saturated. Two checkouts on one machine share its processors, and recording
  the figure per copy would report the same saturation twice and let the two
  disagree.

  A map rather than columns: what a machine can say about itself differs by
  platform and will grow, and a schema change per field is how a reporting
  feature stops being extended.

  ## Dropping `working_copies.tools_seen_at`

  Added yesterday as the signal for "the agent worked again after the restart",
  and wrong. It answers a question about the *machine*, and story 1056's
  criterion 3302 is about the agent: on a healthy machine the column is stamped
  on every join, so every restart resolves immediately and the refusal that
  criterion 3292 exists for could never fire.

  The signal is the agent speaking after the restart — which is what "works
  again" means for an agent, and which needs no column at all.
  """

  use Ecto.Migration

  def change do
    alter table(:devices) do
      add :load, :map
      add :load_reported_at, :utc_datetime_usec
    end

    alter table(:working_copies) do
      remove :tools_seen_at, :utc_datetime_usec
    end
  end
end
