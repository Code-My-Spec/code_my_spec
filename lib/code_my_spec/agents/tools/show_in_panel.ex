defmodule CodeMySpec.Agents.Tools.ShowInPanel do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.ScreenState
  alias CodeMySpec.Stories

  @impl true
  def name, do: "show_in_panel"

  @impl true
  def description do
    """
    Put something in front of the person watching, beside the conversation —
    never the page, so it never costs them the transcript or composer.

    Call it when you start on a story, instead of describing where to look. It
    never interrupts: it applies at once on a screen with room, or waits
    behind a tap on a narrow one. There is no screen argument and no "was this
    seen" answer — the view resolves that, and neither is something you act on.
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:meta, :integer,
         [description: "Which story, when view is \"story\". Ignored otherwise."]},
      view:
        {:required,
         {:meta, :string,
          [
            description:
              "What the panel should show. \"stories\" for the project's list, \"story\" for one, \"epics\" for the project's epics."
          ]}}
    }
  end

  @views ~w(stories story epics)

  @impl true
  def call(%{view: view} = params, context) when view in @views do
    scope = context[:scope]

    with {:ok, story_id} <- check_story(scope, view, params[:story_number]),
         {:ok, _screen} <- ScreenState.show(scope, %{view: view, story_id: story_id}) do
      {:ok, said(view, params[:story_number])}
    else
      {:error, :no_such_story} ->
        {:error,
         """
         Story #{params[:story_number]} is not on this project, so the panel was not changed.

         Pointing a panel at a story that is not there would leave the person
         looking at an error where they expected their own work. Check the number
         with `list_story_titles`.
         """}

      _ ->
        {:error, "Could not record what to show. This needs a scope with a user and a project."}
    end
  end

  def call(%{view: view}, _context) do
    {:error,
     "#{inspect(view)} is not something the panel can show. Use #{Enum.join(@views, " or ")}."}
  end

  # Checked here rather than left to the view. The panel would say the story is
  # gone, which is the right thing for a story deleted after the fact and the
  # wrong thing for an id that was never right — the agent can fix the second
  # and only the agent knows it made it up.
  defp check_story(_scope, "stories", _number), do: {:ok, nil}
  defp check_story(_scope, "epics", _number), do: {:ok, nil}
  defp check_story(_scope, "story", nil), do: {:error, :no_such_story}

  defp check_story(scope, "story", number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, :no_such_story}
      story -> {:ok, story.id}
    end
  end

  defp said("story", number), do: "The panel is showing story #{number}."

  defp said("stories", _id),
    do: "The panel is showing this project's stories."

  defp said("epics", _id),
    do: "The panel is showing this project's epics."
end
