defmodule CodeMySpec.Repo.Migrations.ConversationsBelongToAgents do
  @moduledoc """
  A conversation belongs to an agent.

  It was keyed on the working copy — `session_external_id` as `pi:<root>` —
  holding "the whole team's transcript". That was deliberate and it stopped
  serving: a copy runs several lanes, their turns interleave into one thread,
  and a reply cannot say which agent spoke.

  ## The old rows are deleted, not migrated

  A decision rather than a cleanup. They hold real transcripts, including turns
  from before the agent engine changed. There is no agent to attach them to —
  the agents that produced them are stopped, and most were never rows — so
  keeping them would mean either a second shape in this table forever or
  inventing placeholder agents that never existed.

  Support conversations are untouched. Only `type: :agent` rows go.
  """

  use Ecto.Migration

  def up do
    alter table(:conversations) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
    end

    # Deliberate, and irreversible: see the moduledoc. Scoped to agent threads
    # so a support conversation is never caught by it.
    execute("DELETE FROM conversations WHERE type = 'agent'")

    create index(:conversations, [:agent_id])

    # One conversation per agent. `session_external_id` keeps its own index for
    # the rows that still use it, but it is no longer what identifies an agent
    # thread.
    create unique_index(:conversations, [:agent_id],
             where: "agent_id IS NOT NULL",
             name: :conversations_agent_index
           )
  end

  def down do
    drop index(:conversations, [:agent_id], name: :conversations_agent_index)
    drop index(:conversations, [:agent_id])

    alter table(:conversations) do
      remove :agent_id
    end

    # The deleted transcripts do not come back. Said out loud because a `down`
    # that silently restores nothing is worse than one that admits it.
  end
end
