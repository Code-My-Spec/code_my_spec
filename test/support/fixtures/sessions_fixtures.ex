defmodule CodeMySpec.SessionsFixtures do
  @moduledoc """
  Test helpers for creating sessions via the `CodeMySpec.Sessions` context.
  """

  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions
  alias CodeMySpec.Sessions.Session

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

  @doc """
  Generate a session with a pre-attached active task.

  Defaults to `execution_type: :main_agent, validation_type: :automatic,
  status: :active`. Overrides via `task_attrs`.

  Use for spec scenarios that need a specific task shape (subagent,
  manual validation, continuous mode) where driving the real
  orchestrator flow is impractical — server-side-originated state
  that syncs into the local app.
  """
  def session_with_task_fixture(scope, session_attrs \\ %{}, task_attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task_attrs =
      Enum.into(task_attrs, %{
        status: :active,
        execution_type: :main_agent,
        validation_type: :automatic,
        started_at: now,
        project_id: scope.active_project_id
      })

    session = session_fixture(scope, session_attrs)

    {:ok, updated} =
      session
      |> Session.add_task(task_attrs)
      |> Repo.update()

    updated
  end
end
