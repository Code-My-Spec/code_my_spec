defmodule CodeMySpec.Agents.CompletionHandoffs do
  @moduledoc "Assigned artifact work, durable completion, and explicit main acknowledgement."
  import Ecto.Query
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.{Agent, CompletionHandoff}
  alias CodeMySpec.Repo

  def pending(scope) do
    Repo.all(
      from(h in CompletionHandoff,
        where: h.project_id == ^scope.active_project_id and h.status == :completed,
        order_by: [asc: h.completed_at]
      )
    )
  end

  def list(scope),
    do:
      Repo.all(
        from(h in CompletionHandoff,
          where: h.project_id == ^scope.active_project_id,
          order_by: [desc: h.inserted_at]
        )
      )

  def assign(scope, main_id, attrs) do
    with :ok <- main?(scope, main_id),
         {:ok, owner} <- Agents.fetch_agent(scope, attrs[:owner_agent_id]),
         true <- owner.role == :coding and owner.working_copy_id == attrs[:working_copy_id] do
      %CompletionHandoff{}
      |> CompletionHandoff.changeset(
        Map.merge(attrs, %{project_id: scope.active_project_id, assigned_by_agent_id: main_id})
      )
      |> Repo.insert()
    else
      false -> {:error, :owner_not_authorized_for_copy}
      error -> error
    end
  end

  @evidence [:artifact_sha, :parent_commit, :parent_gitlink, :verification]

  def complete(scope, owner_id, task_id, id, attrs) do
    result =
      Repo.transaction(fn ->
        handoff = fetch_locked!(scope, id)

        case {handoff.owner_agent_id, handoff.task_id, handoff.status} do
          {^owner_id, ^task_id, :assigned} ->
            {record_completion(handoff, attrs), :new}

          {^owner_id, ^task_id, state} when state in [:completed, :acknowledged] ->
            {same_completion!(handoff, attrs), :existing}

          _ ->
            Repo.rollback(:not_assigned_owner_or_task)
        end
      end)

    case result do
      {:ok, {handoff, :new}} ->
        dispatch(scope, handoff)
        {:ok, handoff}

      {:ok, {handoff, :existing}} ->
        {:ok, handoff}

      error ->
        error
    end
  end

  defp record_completion(handoff, attrs) do
    unless Enum.all?(@evidence, &present?(attrs[&1])),
      do: Repo.rollback(:completion_evidence_required)

    unless attrs[:artifact_sha] == attrs[:parent_gitlink],
      do: Repo.rollback(:gitlink_does_not_match_artifact)

    update!(
      handoff,
      Map.merge(Map.take(attrs, @evidence), %{
        status: :completed,
        completed_at: DateTime.utc_now()
      })
    )
  end

  # A repeated completion is idempotent only when it carries the same evidence.
  defp same_completion!(handoff, attrs) do
    unless Enum.all?(@evidence, &(Map.get(handoff, &1) == attrs[&1])),
      do: Repo.rollback(:conflicting_completion)

    handoff
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  def acknowledge(scope, main_id, id, note) when is_binary(note) and byte_size(note) > 0 do
    with :ok <- main?(scope, main_id) do
      Repo.transaction(fn ->
        handoff = fetch_locked!(scope, id)

        case handoff.status do
          :completed ->
            update!(handoff, %{
              status: :acknowledged,
              acknowledged_at: DateTime.utc_now(),
              acknowledged_by_agent_id: main_id,
              acknowledgement: note
            })

          :acknowledged ->
            handoff

          :assigned ->
            Repo.rollback(:completion_not_recorded)
        end
      end)
      |> publish()
    end
  end

  defp publish({:ok, handoff} = result) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      "completion_handoffs:#{handoff.project_id}",
      {:completion_handoff, handoff}
    )

    result
  end

  defp publish(error), do: error

  def recover(scope, copy_id) do
    case Agents.main_agent(scope) do
      %Agent{working_copy_id: ^copy_id} -> Enum.each(pending(scope), &dispatch(scope, &1))
      _ -> :ok
    end
  end

  def redeliver(scope, main_id, id) do
    with :ok <- main?(scope, main_id),
         %CompletionHandoff{status: :completed} = handoff <-
           Repo.get_by(CompletionHandoff, id: id, project_id: scope.active_project_id) do
      dispatch(scope, handoff)
      {:ok, handoff}
    else
      {:error, _} = error -> error
      _ -> {:error, :no_pending_completion}
    end
  end

  def message(handoff) do
    "Completion handoff #{handoff.id} (#{handoff.identity}): #{handoff.status}. " <>
      "Owner: #{handoff.owner_agent_id}; copy: #{handoff.working_copy_id}; task: #{handoff.task_id}. " <>
      "Artifacts: #{Enum.join(handoff.artifact_paths, ", ")}; base: #{handoff.reviewed_base}; purpose: #{handoff.purpose}; authorship: #{handoff.authorship}. " <>
      "Artifact SHA: #{handoff.artifact_sha || "pending"}; parent: #{handoff.parent_commit || "pending"}; gitlink: #{handoff.parent_gitlink || "pending"}. " <>
      "Delivery: #{handoff.delivery_state}; acknowledgement: #{handoff.acknowledgement || "pending"}. " <>
      "Next action: #{handoff.next_action}. Main must review and explicitly acknowledge with completion_handoff; receipt alone is not acknowledgement or QA certification."
  end

  defp dispatch(scope, handoff) do
    # Completion is already durable. Keep transport and delivery bookkeeping
    # owned by this caller rather than leaving a database task behind it.
    # An interrupted caller leaves the record pending for reconnect recovery.
    result =
      case Agents.main_agent(scope) do
        nil ->
          {:error, :main_unavailable}

        main ->
          Agents.send_to_agent(main.id, message(handoff), :own_reply,
            offer: {:instruction, {"completion_handoff", handoff.id}}
          )
      end

    record_delivery(scope, handoff.id, result)
  end

  defp record_delivery(scope, id, result) do
    {state, error} =
      case result do
        {:ok, :started} -> {:delivered, nil}
        {:ok, :queued} -> {:queued, nil}
        {:ok, :not_runnable} -> {:pending, "main_not_runnable"}
        {:error, :message_timed_out} -> {:unknown, "message_timed_out"}
        {:error, reason} -> {:failed, inspect(reason)}
      end

    Repo.transaction(fn ->
      handoff = fetch_locked!(scope, id)

      case handoff.delivery_state do
        :delivered -> handoff
        _ -> update!(handoff, %{delivery_state: state, delivery_error: error})
      end
    end)
  end

  def delivered(message_id, agent) do
    ids =
      Repo.all(
        from(o in CodeMySpec.Agents.Offer,
          join: link in CodeMySpec.Agents.OfferMessage,
          on: link.offer_id == o.id,
          where:
            link.message_id == ^message_id and o.agent_id == ^agent.id and
              o.project_id == ^agent.project_id and o.subject_type == "completion_handoff",
          select: o.subject_key
        )
      )

    Enum.each(ids, fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          from(h in CompletionHandoff, where: h.id == ^uuid and h.project_id == ^agent.project_id)
          |> Repo.update_all(
            set: [delivery_state: :delivered, delivery_error: nil, updated_at: DateTime.utc_now()]
          )

        :error ->
          :ok
      end
    end)

    :ok
  end

  defp main?(scope, id) do
    case Agents.main_agent(scope) do
      %Agent{id: ^id} -> :ok
      _ -> {:error, :only_project_main}
    end
  end

  defp fetch_locked!(scope, id) do
    case Repo.one(
           from(h in CompletionHandoff,
             where: h.project_id == ^scope.active_project_id and h.id == ^id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> Repo.rollback(:handoff_not_found)
      handoff -> handoff
    end
  end

  defp update!(handoff, attrs) do
    case handoff |> CompletionHandoff.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, error} -> Repo.rollback(error)
    end
  end
end
