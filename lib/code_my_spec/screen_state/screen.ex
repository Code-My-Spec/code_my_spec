defmodule CodeMySpec.ScreenState.Screen do
  @moduledoc """
  What one person's screen is showing for one project.

  The defaults live here rather than in the migration, so a person who has never
  opened the screen is a struct rather than a row — `ScreenState.get/1` hands
  back this struct's defaults when there is nothing stored, and the caller
  cannot tell the difference. That is what keeps "first visit" out of every
  render.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "screen_states" do
    # Shut. The panels are furniture around a conversation, and a screen that
    # opens with three panes open has decided for somebody what they came for.
    field :open_panels, {:array, :string}, default: []

    field :dynamic_view, :string, default: "stories"
    field :dynamic_story_id, :id

    # What the agent asked for and has not been given yet. Both nil on a screen
    # nobody is steering, which is the ordinary state.
    field :offered_view, :string
    field :offered_story_id, :id

    field :user_id, :id
    belongs_to :project, CodeMySpec.Projects.Project

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(open_panels dynamic_view dynamic_story_id offered_view offered_story_id)a

  def changeset(screen, attrs, %{user_id: user_id, project_id: project_id}) do
    screen
    |> cast(attrs, @fields)
    |> put_change(:user_id, user_id)
    |> put_change(:project_id, project_id)
    |> validate_panels()
    |> unique_constraint([:user_id, :project_id])
  end

  # Only panels that exist. A stored name nothing renders is a panel that is
  # open and invisible, and the count of open panels is what the phone rule is
  # written against — so a junk entry there would make "at most one open" wrong
  # in a way nothing on screen could show.
  @panels ~w(preview dynamic activity)

  defp validate_panels(changeset) do
    case get_field(changeset, :open_panels) do
      nil ->
        changeset

      panels ->
        case Enum.reject(panels, &(&1 in @panels)) do
          [] -> changeset
          junk -> add_error(changeset, :open_panels, "unknown panel(s): #{Enum.join(junk, ", ")}")
        end
    end
  end
end
