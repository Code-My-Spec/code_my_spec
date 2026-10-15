defmodule CodeMySpec.McpServers.Tasks.Tools.ShowInPanel do
  @moduledoc """
  Put something in front of the person watching, on the screen they already
  have open.

  The agent knows which story it is talking about. Making the person go and
  find it is the errand story 967 exists to remove — so instead of describing
  where to look, point the panel at it.

  ## This asks rather than commands, and the screen decides

  Whether the change lands immediately is a property of the screen, not of the
  change. A wide one holds every panel at once, so swapping the dynamic tab
  costs nothing and it simply appears. A phone holds one panel, so applying it
  would evict whatever the person was watching — possibly while they are
  part-way through typing — and it waits behind a mark until they tap it.

  Nothing here needs to know which. `ScreenState.show/2` records the intent and
  the view resolves it, which is why this tool takes no screen argument and
  cannot be made to interrupt somebody.

  ## Why it is not "navigate"

  It changes one panel beside the conversation, never the page. An agent that
  could navigate the person somewhere would take the transcript and the
  composer with it, and the whole design of that screen is that watching and
  asking do not cost each other.

  Silent about whether anybody is looking, on purpose. A screen nobody has open
  still records the intent and shows it when they arrive, and reporting
  "delivered" versus "stored" would be a distinction the agent cannot act on.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.ScreenState
  alias CodeMySpec.Stories

  schema do
    field :view, :string,
      required: true,
      description:
        ~s(What the panel should show. "stories" for the project's list, "story" for one, ) <>
          ~s("epics" for the project's epics.)

    field :story_number, :integer, description: "Which story, when view is \"story\". Ignored otherwise."
  end

  @views ~w(stories story epics)

  @impl true
  def execute(%{view: view} = params, frame) when view in @views do
    scope = frame.assigns[:current_scope]

    with {:ok, story_id} <- check_story(scope, view, params[:story_number]),
         {:ok, _screen} <- ScreenState.show(scope, %{view: view, story_id: story_id}) do
      {:reply, Response.tool() |> Response.text(said(view, params[:story_number])), frame}
    else
      {:error, :no_such_story} ->
        {:reply,
         Response.tool()
         |> Response.error("""
         Story #{params[:story_number]} is not on this project, so the panel was not changed.

         Pointing a panel at a story that is not there would leave the person
         looking at an error where they expected their own work. Check the number
         with `list_story_titles`.
         """), frame}

      _ ->
        {:reply,
         Response.tool()
         |> Response.error(
           "Could not record what to show. This needs a scope with a user and a project."
         ), frame}
    end
  end

  def execute(%{view: view}, frame) do
    {:reply,
     Response.tool()
     |> Response.error(
       "#{inspect(view)} is not something the panel can show. Use #{Enum.join(@views, " or ")}."
     ), frame}
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
