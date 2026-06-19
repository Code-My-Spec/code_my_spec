defmodule CodeMySpec.SessionsFixtures do
  @moduledoc """
  Test helpers for creating sessions via the `CodeMySpec.Sessions` context.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

  @doc """
  Generate a session in the given scope.

  Accepts `:tasks` (a list of embedded-task attr maps) and, for timeline
  scenarios that need a controllable position/extent, `:inserted_at` and
  `:updated_at` overrides. The timestamp overrides are applied with a
  direct `update_all` after creation (Ecto manages `inserted_at`/`updated_at`
  on insert) and are merged back onto the returned struct so the embedded
  tasks stay intact.
  """
  def session_fixture(scope, attrs \\ %{}) do
    {timestamps, attrs} =
      attrs
      |> Enum.into(%{})
      |> Map.split([:inserted_at, :updated_at])

    attrs =
      Enum.into(attrs, %{
        state: %{},
        status: :active,
        type: CodeMySpec.AgentTasks.ContextSpec
      })

    {:ok, session} = Sessions.create_session(scope, attrs)

    if map_size(timestamps) > 0 do
      {1, _} =
        from(s in Session, where: s.id == ^session.id)
        |> Repo.update_all(set: Map.to_list(timestamps))

      Map.merge(session, timestamps)
    else
      session
    end
  end
end
