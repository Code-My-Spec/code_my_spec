defmodule CodeMySpec.SessionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CodeMySpec.Sessions` context.
  """

  @doc """
  Generate a session.
  """
  def session_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        agent: :claude_code,
        environment_type: :local,
        state: %{},
        status: :active,
        type: CodeMySpec.AgentTasks.ContextSpec,
        display_name: "Context Spec"
      })

    {:ok, session} = CodeMySpec.Sessions.create_session(scope, attrs)

    CodeMySpec.Repo.preload(session, [:project, :component])
  end
end
