defmodule CodeMySpec.Repo.Migrations.OrchestratorMessagesBecomeTheMessagesTheyAlwaysWere do
  @moduledoc """
  Retires the `orchestrator` message role.

  `:orchestrator` marked "what was done *to* this agent rather than by it", and
  `Chat.Runner.to_provider_message/1` has a catch-all `do: []` that drops every
  role it does not name — `:user`, `:operator`, `:assistant`, `:tool`. So an
  orchestrator row was never in any model's context. It was shown to the person
  watching and to nobody else.

  Story 985 built seven criteria on the other reader, and criterion 3036 records
  in its own moduledoc that it does not exist: "there is no tool today with
  which an agent reads its own conversation". So the whole role delivered
  nothing to anyone it named.

  Two of the nine writers were genuinely sending — a user's answer, and a stop
  decision — and they dispatch through the transport directly rather than
  through `Agents.dispatch_message/3`, which is what normally records. Their
  orchestrator row was therefore the *only* transcript record of a message the
  agent really did receive. Those rows are kept and relabelled `operator`,
  which is what a message from the user's side already is, and which the model
  is given.

  The rest said something to an agent that never heard it. They are gone from
  the code, and their rows go with them — a transcript line claiming the agent
  was told something it was not is worse than no line.

  `operator` for the survivors is decided by `kind`, the part the writer
  stamped: `answer` and `decision` were sent, everything else was not.

  Irreversible by design. `down` cannot know which `operator` rows were once
  orchestrator ones, and inventing that mapping would relabel real user
  messages.
  """

  use Ecto.Migration

  def up do
    # The two that were really delivered keep their place in the transcript.
    execute """
    UPDATE conversation_messages
       SET role = 'operator'
     WHERE role = 'orchestrator'
       AND content @> '[{"type": "kind", "text": "answer"}]'
    """

    execute """
    UPDATE conversation_messages
       SET role = 'operator'
       WHERE role = 'orchestrator'
       AND content @> '[{"type": "kind", "text": "decision"}]'
    """

    # Everything else claimed to tell an agent something it was never told.
    execute "DELETE FROM conversation_messages WHERE role = 'orchestrator'"
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "Irreversible: the orchestrator rows that were not delivered are deleted, " <>
          "and the two kinds that were cannot be told apart from ordinary operator " <>
          "messages once relabelled."
  end
end
