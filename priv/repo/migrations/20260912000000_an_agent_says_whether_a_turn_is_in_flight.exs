defmodule CodeMySpec.Repo.Migrations.AnAgentSaysWhetherATurnIsInFlight do
  @moduledoc """
  Whether an agent is mid-response, which nothing recorded.

  Story 1054, criteria 3297 and 3279. A turn starting reaches the server as an
  `agent_turn_event` and is written to the transcript as a step; a turn *ending*
  writes nothing at all — it is the moment the stop decision speaks, and that
  is all it is. So "is this agent busy" was underivable from what we stored: the
  transcript has a beginning with no end, and an agent eight minutes into a long
  reasoning turn looks exactly like one that died eight minutes ago.

  That is the expensive confusion on this story. The remedy for a stalled agent
  is a restart, and restarting one mid-turn discards the work, wastes the model
  spend, and starts the same turn again from the beginning.

  One nullable timestamp rather than a boolean, because 3276 wants the clock and
  not just the state: how long a turn has been running is what separates a long
  turn from a wedged one, and a flag cannot say.

  Null is the ordinary state and means no turn is open — including for every row
  written before this column existed, which is right: a turn in flight when this
  ships ends without ever being seen, and claiming otherwise would report every
  idle agent as busy forever.
  """

  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :turn_started_at, :utc_datetime_usec
    end
  end
end
