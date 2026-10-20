defmodule CodeMySpec.Repo.Migrations.ATerminalAgentKeepsItsTranscriptPath do
  use Ecto.Migration

  # Story 1129: the file an external agent's session writes (a Claude Code
  # transcript, a Codex rollout), handed over by its SessionStart hook. A
  # re-attach after a harness restart reads it back rather than deriving it.
  def change do
    alter table(:agents) do
      add(:transcript_path, :string)
    end
  end
end
