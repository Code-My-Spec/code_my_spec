defmodule CodeMySpec.Repo.Migrations.AnAgentCarriesTheListOfWhatItMayCall do
  @moduledoc """
  Story 982. Which tools an agent may call is a list on the agent, not a rule
  read off its role.

  The obvious shape was the other one — ask the type at call time and decide
  from it — and John's call was this. The difference shows the first time
  somebody wants an exception: a QA agent needing one extra tool for one project
  is a new role under the implicit scheme, or a `case` inside the check. Here it
  is a different list on one row.

  It also makes the answer readable. "What may this agent call" becomes a column
  rather than a function of a column and a table somewhere else, which matters
  when the question is being asked about an agent that is already running and
  doing something surprising.

  ## Nullable, and that is the honest third state

  Not backfilled. An empty list would have to mean "everything" for the rows
  that predate this, which is the implicit magic the column exists to remove —
  and writing the full catalogue in would be a copy that goes stale the day a
  tool is added, dressed up as a decision somebody made.

  So `nil` means what it is: this agent was started before anything scoped one,
  and could call everything. `Agents.ToolSets` reads it that way, every new
  agent gets a real list, and the state disappears as the old rows do.
  """

  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :tools, {:array, :string}
    end
  end
end
