defmodule CodeMySpec.Repo.Migrations.AnOperatorMessageRecordsWhetherItLanded do
  @moduledoc """
  A message sent at an agent is not the same as a message the agent has.

  Until now a transcript said only that something was said. That was true while
  the only reader was a person looking at a support thread, and false the moment
  the other end is a process that may be mid-turn, stopped, or on a machine
  nobody can reach — three states a row with no delivery column claims are one.

  `delivery_ref` is the operator's handle on it, minted before the message
  leaves and carried by the machine, so a withdrawal names the message rather
  than describing it. Two identical messages are indistinguishable by text at
  exactly the moment it matters.

  Null for everything that is not an operator message at an agent. A widget
  message has no delivery question — it is already where it was going.
  """
  use Ecto.Migration

  def change do
    alter table(:conversation_messages) do
      add :delivery, :string
      add :delivery_ref, :string
    end

    # Withdrawing looks a message up by its ref, on a table that grows a row per
    # step of every turn.
    create index(:conversation_messages, [:delivery_ref])
  end
end
