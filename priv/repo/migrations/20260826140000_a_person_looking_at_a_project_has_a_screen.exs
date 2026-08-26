defmodule CodeMySpec.Repo.Migrations.APersonLookingAtAProjectHasAScreen do
  use Ecto.Migration

  @moduledoc """
  What one person's screen is showing for one project.

  Keyed on both, which is the decision rather than an implementation detail.
  `user_preferences` already holds per-user session state and would have been
  cheaper, but it is one row per user — a layout stored there would carry the
  story you were reading in one project into the next, where it looks like that
  project's state and is not.

  ## The offer, and why it is separate from what is shown

  `dynamic_view` is what the panel is showing. `offered_view` is what the agent
  has asked it to show and has not been allowed to yet.

  They are separate because whether an agent's change applies is a property of
  the screen rather than of the change. A wide screen holds every panel at once,
  so the change costs nothing and is taken immediately. A phone holds one, so
  applying it would evict whatever the person was watching — possibly mid
  sentence in the composer — and it waits behind a mark instead.

  The server cannot know which it is until the client reports its width, so the
  writer records the intent and the screen decides. Collapsing these into one
  column would mean the agent either always interrupts or never steers.

  ## Nothing here is defaulted in the migration

  Defaults live on the schema. A row is created by the app or not at all, and a
  person who has never opened the screen has no row rather than a row full of
  guesses — which is also why every column here is nullable.
  """

  def change do
    create table(:screen_states, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # Which panels are open. An array rather than three booleans because the
      # phone rule is "at most one", which is a property of the list.
      add :open_panels, {:array, :string}

      add :dynamic_view, :string
      add :dynamic_story_id, references(:stories, on_delete: :nilify_all)

      # What the agent asked for and has not been given yet. Nullified rather
      # than cascaded for the same reason the shown story is: a deleted story
      # must not take somebody's screen with it.
      add :offered_view, :string
      add :offered_story_id, references(:stories, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    # One screen per person per project. The unique index is the whole point of
    # the compound key — without it a second row is a second, invisible screen.
    create unique_index(:screen_states, [:user_id, :project_id])
  end
end
