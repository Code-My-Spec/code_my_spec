defmodule CodeMySpec.SessionsFixtures do
  @moduledoc """
  Test helpers for creating sessions via the `CodeMySpec.Sessions` context.
  """

  @doc """
  Generate a session in the given environment.
  """
  def session_fixture(env, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        state: %{},
        status: :active,
        type: CodeMySpec.AgentTasks.ContextSpec
      })

    {:ok, session} = CodeMySpec.Sessions.create_session(env, attrs)

    session
  end
end
