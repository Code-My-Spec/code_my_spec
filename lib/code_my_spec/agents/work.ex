defmodule CodeMySpec.Agents.Work do
  @moduledoc "Eligibility and atomic turn admission for existing durable role agents."

  import Ecto.Query

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Transport
  alias CodeMySpec.Conversations
  alias CodeMySpec.MainAgent
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements

  @prompt "Eligible work is available. Use list_requirements or get_next_requirement to inspect it, " <>
            "then choose work with start_task. No task has been selected or assigned for you."

  def consider_project(scope, reason) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.each(&request_turn_if_runnable(scope, &1, reason))

    :ok
  end

  def consider_copy(scope, copy_id, reason, except_agent_id \\ nil) do
    scope
    |> AgentsRepository.list_agents()
    |> Enum.filter(&(&1.working_copy_id == copy_id and &1.id != except_agent_id))
    |> Enum.each(&request_turn_if_runnable(scope, &1, reason))

    :ok
  end

  def request_turn_if_runnable(scope, %Agent{} = agent, _reason) do
    with {:ok, current} <- AgentsRepository.fetch_agent(scope, agent.id),
         true <- runnable_state?(current),
         true <- eligible_work?(scope, current),
         {:ok, {reserved, ref}} <- reserve(scope, current.id) do
      turn_prompt = prompt(reserved)

      # Recorded as well as sent, and recorded first — the same reasoning as
      # `StopDecision.send_to/3`, which records because it dispatches through
      # the transport directly rather than through `Agents.send_to_agent/2`.
      #
      # Without it a turn arrives out of nowhere: the transcript shows an agent
      # that suddenly started working with nothing in front of it saying why,
      # which is precisely what an operator watching an autonomous fleet needs
      # to be able to read. `wake` recorded its message for the same reason,
      # and the retirement took the recording with it — story 1050 measures
      # routing off these rows, and every correctly routed turn read as
      # silence.
      Conversations.record_sent_to_agent(reserved, turn_prompt)

      case Transport.impl().request_work_turn(
             reserved.working_copy_id,
             reserved,
             ref,
             turn_prompt,
             5_000
           ) do
        {:ok, :started} ->
          {:ok, ref}

        error ->
          release(scope, reserved.id, ref)
          error
      end
    else
      false -> {:ok, :not_runnable}
      {:ok, :not_runnable} = result -> result
      error -> error
    end
  end

  def release(scope, agent_id, ref) do
    from(a in Agent,
      where:
        a.id == ^agent_id and a.project_id == ^scope.active_project_id and
          a.account_id == ^scope.active_account_id and a.work_request_id == ^ref
    )
    |> Repo.update_all(set: [work_request_id: nil, work_requested_at: nil])

    :ok
  end

  defp reserve(scope, id) do
    Repo.transaction(fn ->
      agent =
        Repo.one(
          from a in Agent,
            where:
              a.id == ^id and a.project_id == ^scope.active_project_id and
                a.account_id == ^scope.active_account_id,
            lock: "FOR UPDATE"
        )

      if agent && runnable_state?(agent), do: reserve(agent), else: :not_runnable
    end)
  end

  # Stamping the reservation is what makes the request idempotent: two events
  # racing to admit the same agent both take the row lock above, and only the
  # first sees a runnable state to stamp.
  defp reserve(agent) do
    ref = Ecto.UUID.generate()

    agent
    |> Agent.changeset(%{work_request_id: ref, work_requested_at: DateTime.utc_now()})
    |> Repo.update()
    |> case do
      {:ok, saved} -> {saved, ref}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp runnable_state?(agent) do
    agent.status == :running and agent.continuous and is_nil(agent.turn_started_at) and
      is_nil(agent.work_request_id) and is_nil(Agent.active_task(agent)) and
      not is_nil(agent.working_copy_id)
  end

  defp eligible_work?(scope, agent) do
    question_work?(scope, agent) or graph_work?(scope, agent)
  end

  defp question_work?(scope, %{role: :main}) do
    Enum.any?(MainAgent.list_open_questions(scope), &(&1.holder == "main_agent"))
  end

  defp question_work?(_scope, _agent), do: false

  defp prompt(%{role: :main}) do
    @prompt <> " Also inspect list_notifications for questions held by the main agent."
  end

  defp prompt(_agent), do: @prompt

  defp graph_work?(scope, agent) do
    scope = %{scope | active_working_copy_id: agent.working_copy_id}
    owners = AgentsRepository.list_agents(scope)

    scope
    |> Requirements.actionable_for_role(agent.role)
    |> Enum.any?(fn node -> not held?(owners, agent, node) end)
  end

  defp held?(owners, agent, node) do
    owners
    |> Enum.filter(&(&1.working_copy_id == agent.working_copy_id))
    |> Enum.any?(fn owner ->
      Enum.any?(owner.tasks || [], &holds_node?(&1, owner.id == agent.id, node))
    end)
  end

  defp holds_node?(task, mine?, node) do
    task.requirement_name == node.name and
      entity_id(task, node.entity_type) == to_string(node.entity_id) and
      (task.status == :active or
         (task.status == :blocked and (not mine? or is_nil(task.blocker_resolved_at))))
  end

  defp entity_id(task, "story"), do: to_string(task.story_id)
  defp entity_id(task, "component"), do: to_string(task.component_id)
  defp entity_id(task, "project"), do: to_string(task.project_id)
  defp entity_id(_task, _type), do: nil
end
