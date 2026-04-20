defmodule CodeMySpec.SessionsFixtures do
  @moduledoc """
  Test helpers for creating sessions via the `CodeMySpec.Sessions` context.
  """

  alias CodeMySpec.Sessions

  @doc """
  Generate a session in the given scope.
  """
  def session_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        state: %{},
        status: :active,
        type: CodeMySpec.AgentTasks.ContextSpec
      })

    {:ok, session} = Sessions.create_session(scope, attrs)

    session
  end
end
