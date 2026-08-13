defmodule CodeMySpec.Repo.Migrations.LinkQuestionRequestsToASession do
  @moduledoc """
  Which conversation a question came out of.

  A question request knew only its user. So a notification could show the
  question and nothing around it — there was nowhere to navigate to, because
  nothing recorded where it was asked. The plan is the opposite: the
  notification takes you to the conversation, and you answer with the work that
  prompted the question visible.

  Claude's own session id, the same key a conversation is named by, so the two
  join without a foreign key between them. The asking agent does not know it —
  `ask_user` runs with a scope carrying a harness, not a session — so the
  server resolves it from the working copy on the way in, exactly as a recorded
  model turn does.

  Nullable. A question asked outside a harness has no conversation, and that is
  a real state rather than a missing value: it still notifies, it just has
  nowhere to link.
  """
  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :session_external_id, :string
    end

    create index(:question_requests, [:session_external_id])
  end
end
