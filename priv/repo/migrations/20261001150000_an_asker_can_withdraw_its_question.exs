defmodule CodeMySpec.Repo.Migrations.AnAskerCanWithdrawItsQuestion do
  @moduledoc """
  8c91d5bc: an agent's question that went moot could not be taken back, so the
  task it blocked waited on a customer for 20+ minutes. A withdrawn question
  carries the asker's reason; `status` gains `withdrawn` in the schema. No
  default: only a withdrawal writes it.
  """

  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :withdrawn_reason, :text
    end
  end
end
