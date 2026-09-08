defmodule CodeMySpec.ScreenState do
  @moduledoc """
  What a person's screen is showing for one project, and the one thing that
  writes it.

  Two callers, and they are not symmetrical.

  The **person** changes their own screen — opens a panel, switches what the
  dynamic tab is showing — and that is simply stored. The **agent** asks for a
  change through `show/2`, and what happens next depends on the screen it lands
  on rather than on the change itself.

  ## Why the agent's change is recorded as an offer

  A wide screen holds every panel at once, so an agent swapping the dynamic tab
  costs nothing: nothing has to close to make room, and asking permission for it
  would be ceremony. A phone holds one panel, so applying the same change evicts
  whatever the person was watching — possibly while they are part-way through
  typing.

  The server cannot tell which it is. Width reaches it only when the client
  reports it, and the report belongs to a LiveView rather than to this. So
  `show/2` records the intent and the screen decides: a wide one calls `take/1`
  immediately, a narrow one renders a mark and calls `take/1` when the person
  taps it.

  Collapsing the offer into `dynamic_view` would force one of the two bad
  answers — an agent that always interrupts, or one that cannot steer at all.

  ## Reading it

  `get/1` never returns nil. A person who has never opened the screen gets
  `%Screen{}`'s defaults, so nothing downstream has a "first visit" branch.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.ScreenState.Screen
  alias CodeMySpec.Utils.MapAccess

  @doc """
  This person's screen for this project, defaults included.
  """
  @spec get(map()) :: Screen.t()
  def get(scope) do
    case key(scope) do
      nil -> %Screen{}
      {user_id, project_id} -> stored(user_id, project_id) || %Screen{}
    end
  end

  @doc """
  Store what the person did to their own screen.

  Their own, so it applies rather than waiting: nobody needs to be offered a
  panel they just opened.
  """
  @spec put(map(), map()) :: {:ok, Screen.t()} | {:error, Ecto.Changeset.t()} | :error
  def put(scope, attrs) do
    case key(scope) do
      {user_id, project_id} ->
        (stored(user_id, project_id) || %Screen{})
        |> Screen.changeset(attrs, %{user_id: user_id, project_id: project_id})
        |> Repo.insert_or_update()
        |> announce(scope)

      _ ->
        :error
    end
  end

  @doc """
  The agent asks for the screen to show something.

  Recorded as an offer rather than applied — see the moduledoc. Broadcasts
  either way, because a screen that is wide enough to take it immediately still
  has to hear that there is something to take.
  """
  @spec show(map(), map()) :: {:ok, Screen.t()} | {:error, Ecto.Changeset.t()} | :error
  def show(scope, %{} = attrs) do
    put(scope, %{
      offered_view: MapAccess.get(attrs, :view),
      offered_story_id: MapAccess.get(attrs, :story_id)
    })
  end

  @doc """
  Accept whatever is being offered, and clear the offer.

  Called by the screen — immediately where the change is free, and on a tap
  where it is not. A no-op when nothing is offered, so a screen that takes on
  every render cannot loop.
  """
  @spec take(map()) :: {:ok, Screen.t()} | {:error, Ecto.Changeset.t()} | :error
  def take(scope) do
    case get(scope) do
      %Screen{offered_view: nil} = screen ->
        {:ok, screen}

      %Screen{} = screen ->
        put(scope, %{
          dynamic_view: screen.offered_view,
          dynamic_story_id: screen.offered_story_id,
          offered_view: nil,
          offered_story_id: nil
        })
    end
  end

  @doc """
  Changes to this person's screen for this project.

  Its own topic rather than the project's: two people looking at one project
  have two screens, and a broadcast that reached both would move a screen its
  owner did not touch.
  """
  @spec subscribe(map()) :: :ok | {:error, term()}
  def subscribe(scope) do
    case key(scope) do
      nil ->
        :ok

      {user_id, project_id} ->
        Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(user_id, project_id))
    end
  end

  defp announce({:ok, screen} = result, scope) do
    with {user_id, project_id} <- key(scope) do
      Phoenix.PubSub.broadcast(
        CodeMySpec.PubSub,
        topic(user_id, project_id),
        {:screen_changed, screen}
      )
    end

    result
  end

  defp announce(other, _scope), do: other

  defp topic(user_id, project_id), do: "screen:#{user_id}:#{project_id}"

  defp stored(user_id, project_id) do
    Repo.one(
      from s in Screen, where: s.user_id == ^user_id and s.project_id == ^project_id, limit: 1
    )
  end

  # Both halves or nothing. A screen belongs to one person looking at one
  # project, and a key missing either is not a screen — storing it under the
  # half that is present is how one project's layout ends up in another.
  defp key(%{active_project_id: project_id} = scope) when is_binary(project_id) do
    case user_id(scope) do
      nil -> nil
      user_id -> {user_id, project_id}
    end
  end

  defp key(_scope), do: nil

  defp user_id(%{user: %{id: id}}) when not is_nil(id), do: id
  defp user_id(%{user_id: id}) when not is_nil(id), do: id
  defp user_id(_scope), do: nil
end
