defmodule CodeMySpec.Repo.Migrations.DropStatusFromStories do
  @moduledoc """
  Drop `stories.status`. It was a cached projection of the requirement graph
  and never once agreed with it.

  Nothing wrote `:completed`. Across 124 stories on this project, every row read
  `in_progress` — including stories sitting at 6/6 satisfied with every box
  ticked. So the column could not answer the question it existed to answer: a
  finished story and an untouched one held the same value, and anything reading
  it was wrong in the same direction for every completed story.

  Worse than a null would have been, because `in_progress` is a positive claim
  that work remains, made about work that is done.

  The fix is not to add the missing writer. This project has been bitten
  repeatedly by exactly this shape — a stored fact drifting from the computed
  one — and adding the forward edge would only have created the need for a
  reverse one the first time a spec changed. The requirement graph already knows,
  per story, and is recomputed rather than remembered. Ask it.

  Irreversible on purpose: `down` restores the column but not its values, since
  there is nothing to restore. Every row held the same wrong answer.
  """
  use Ecto.Migration

  def up do
    alter table(:stories) do
      remove :status
    end
  end

  def down do
    alter table(:stories) do
      add :status, :string
    end
  end
end
