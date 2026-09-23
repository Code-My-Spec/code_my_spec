defmodule CodeMySpec.Repo.Migrations.AStoppedAgentSaysWhetherItWasReaped do
  use Ecto.Migration

  # 73d0d505: `record_stopped/2` is the one path for both a deliberate stop
  # and a harness/machine taking an agent with it, and nothing on the row
  # says which happened -- so the reconnect sweep that could restart a
  # reaped continuous agent cannot tell it apart from one a human meant to
  # leave stopped. Nullable, no default: existing stopped rows predate the
  # distinction and stay nil rather than being guessed at.
  def change do
    alter table(:agents) do
      add :stopped_reason, :string
    end
  end
end
