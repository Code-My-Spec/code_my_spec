defmodule CodeMySpec.Repo.Migrations.APendingModelCallIsOnTheRow do
  use Ecto.Migration

  @moduledoc """
  Whether a model call is in flight for this plan.

  The call ran inside the LiveView's `handle_event`, so the LiveView *was* the
  record of it: reload mid-call and the process died with the request, the answer
  landed nowhere, and the visitor came back to a page that had forgotten it was
  waiting. Nothing was persisted because nothing outlived the socket.

  With the work in a supervised task, the row is what says a call is out. A
  reload reads `:thinking` and renders the same "Thinking…" the first tab is
  showing, and the result reaches both when it arrives.
  """

  def change do
    alter table(:intake_plans) do
      add :shaping_status, :string, null: false, default: "idle"
    end
  end
end
