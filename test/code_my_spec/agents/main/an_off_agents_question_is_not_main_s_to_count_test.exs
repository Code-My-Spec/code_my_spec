defmodule CodeMySpec.Agents.Main.AnOffAgentsQuestionIsNotMainsToCountTest do
  @moduledoc """
  The check-in counts the questions of agents on duty, not of agents somebody
  turned off.

  Every check-in read "questions waiting on others: user 18", all of them a
  month old and raised by agents since turned off, which the same check-in
  tells main to leave off (2026-10-13).
  """
  use CodeMySpecTest.DataCase, async: true

  import Ecto.Query
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.Cadence
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo

  setup do
    scope = full_scope_fixture()
    on_duty = agent(scope)
    off = agent(scope)
    Repo.update_all(from(a in Agent, where: a.id == ^off.id), set: [off_at: DateTime.utc_now()])

    %{scope: scope, live: ask(scope, on_duty, "Ship it?"), stale: ask(scope, off, "Old one?")}
  end

  defp agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :coding,
        status: :running,
        working_copy: "/tmp/off-question-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  defp ask(scope, agent, text) do
    {:ok, request} =
      Notifications.create_question_request(scope.user.id, %{
        "agent_id" => agent.id,
        "holder" => "user",
        "questions" => [%{"question" => text, "options" => []}]
      })

    request
  end

  test "only the on-duty agent's question reaches the check-in", ctx do
    assert [%{id: id}] = Cadence.digest(ctx.scope).questions
    assert id == ctx.live.id
  end
end
