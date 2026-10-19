defmodule CodeMySpec.TerminalAgentFixtures do
  @moduledoc """
  Test helpers for the agent a Claude Code session is (story 1122).

  Every task belongs to an agent. A test that needs "the thing a hook's
  `session_id` names, holding some tasks" builds that terminal agent here.
  """

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Repo

  @doc """
  A terminal agent in the given scope, found again by its session id.

  Accepts `:engine_session_id` (generated when absent), `:role` (default
  `:main`), `:continuous`, `:git_rewrite_at`, `:tasks` (a list of task attr
  maps, embedded as given with no activation rules applied) and, for timeline
  scenarios, `:inserted_at`/`:updated_at` overrides applied by a direct update.
  """
  @spec terminal_agent_fixture(CodeMySpec.Users.Scope.t(), map() | keyword()) :: Agent.t()
  def terminal_agent_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    session_id = Map.get(attrs, :engine_session_id) || "cc-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        engine: :claude_code,
        engine_session_id: session_id,
        provider: "claude-code",
        role: Map.get(attrs, :role, :main),
        working_copy: "/tmp/terminal-agent-fixture-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id,
        status: :running,
        continuous: Map.get(attrs, :continuous, false),
        git_rewrite_at: Map.get(attrs, :git_rewrite_at)
      })

    agent = with_tasks(agent, Map.get(attrs, :tasks, []))

    stamp(agent, Map.take(attrs, [:inserted_at, :updated_at]))
  end

  defp with_tasks(agent, []), do: agent

  defp with_tasks(agent, tasks) do
    Enum.reduce(tasks, agent, fn task_attrs, acc ->
      acc |> Agent.add_task(Map.new(task_attrs)) |> Repo.update!()
    end)
  end

  defp stamp(agent, timestamps) when map_size(timestamps) == 0, do: agent

  defp stamp(agent, timestamps) do
    {1, _} =
      from(a in Agent, where: a.id == ^agent.id)
      |> Repo.update_all(set: Map.to_list(timestamps))

    Map.merge(agent, timestamps)
  end
end
