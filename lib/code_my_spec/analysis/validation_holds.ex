defmodule CodeMySpec.Analysis.ValidationHolds do
  @moduledoc "Durable, owner-controlled validation slots. Terminal execution requests a handoff, never another run."
  import Ecto.Query
  alias CodeMySpec.Analysis.{Run, ValidationHold}
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  def list(%Scope{active_project_id: project_id}) do
    Repo.all(
      from(h in ValidationHold,
        where: h.project_id == ^project_id,
        order_by: [desc: h.inserted_at]
      )
    )
  end

  # Lock the project row for every admission, authorization and promotion
  # transition. Unlike a process lock, this survives a service restart.
  def lock(project_id) do
    Repo.one!(
      from(p in "projects",
        where: p.id == type(^project_id, :binary_id),
        select: p.id,
        lock: "FOR UPDATE"
      )
    )
  end

  def create(scope, attrs) do
    transaction(scope, fn ->
      attrs = creation_attrs!(scope, attrs)

      case %ValidationHold{}
           |> ValidationHold.changeset(Map.put(attrs, :project_id, scope.active_project_id))
           |> Repo.insert() do
        {:ok, hold} -> hold
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp creation_attrs!(scope, %{run_id: run_id} = attrs) when is_integer(run_id) do
    case Repo.one(
           from(r in Run,
             where:
               r.id == ^run_id and r.project_id == ^scope.active_project_id and
                 r.status == :running
           )
         ) do
      %Run{} = run ->
        unless run.working_copy_id in Map.get(attrs, :affected_copy_ids, []),
          do: Repo.rollback(:copy_outside_hold)

        other_runs =
          Repo.exists?(
            from(r in Run,
              where:
                r.project_id == ^scope.active_project_id and r.status == :running and
                  r.id != ^run_id
            )
          )

        if other_runs, do: Repo.rollback(:other_executions_active)
        require_no_promotion!(scope)

        Map.merge(attrs, %{
          status: :running,
          authorized_copy_id: run.working_copy_id,
          source: run.source,
          args: get_in(run.args || %{}, ["args"]) || []
        })

      _ ->
        Repo.rollback(:run_not_active_in_project)
    end
  end

  defp creation_attrs!(scope, attrs) do
    require_idle!(scope)
    Map.put(attrs, :status, :held)
  end

  def authorize(scope, id, owner_id, attrs) do
    transaction(scope, fn ->
      hold = owned!(scope, id, owner_id)

      case hold.status do
        state when state in [:held, :awaiting_handoff] -> :ok
        _ -> Repo.rollback(:execution_not_released)
      end

      require_idle!(scope)
      copy_id = Map.get(attrs, :authorized_copy_id)
      unless copy_id in hold.affected_copy_ids, do: Repo.rollback(:copy_outside_hold)

      unless Map.get(attrs, :source) in Run.sources() and is_list(Map.get(attrs, :args)),
        do: Repo.rollback(:invalid_authorization)

      hold
      |> ValidationHold.changeset(
        Map.merge(
          Map.take(attrs, [:authorized_copy_id, :source, :args, :next_agent_id]),
          %{status: :authorized, run_id: nil, outcome: nil}
        )
      )
      |> persist!()
    end)
  end

  def release(scope, id, owner_id) do
    transaction(scope, fn ->
      hold = owned!(scope, id, owner_id)

      case hold.status do
        state when state in [:held, :authorized, :awaiting_handoff] ->
          hold |> ValidationHold.changeset(%{status: :released}) |> persist!()

        _ ->
          Repo.rollback(:execution_not_released)
      end
    end)
  end

  @doc "Record operator-verified termination evidence; this never certifies validation."
  def confirm_termination(scope, id, owner_id, evidence)
      when is_binary(evidence) and byte_size(evidence) > 0 do
    transaction(scope, fn ->
      hold = owned!(scope, id, owner_id)

      case hold.status do
        :unknown ->
          outcome =
            Map.merge(hold.outcome || %{}, %{
              "execution_known" => true,
              "validation_passed" => false,
              "termination_evidence" => evidence
            })

          hold
          |> ValidationHold.changeset(%{status: :awaiting_handoff, outcome: outcome})
          |> persist!()

        _ ->
          Repo.rollback(:execution_not_unknown)
      end
    end)
  end

  defp owned!(scope, id, owner_id) do
    case Repo.one(
           from(h in ValidationHold,
             where: h.id == ^id and h.project_id == ^scope.active_project_id
           )
         ) do
      %ValidationHold{owner_agent_id: ^owner_id} = hold -> hold
      _ -> Repo.rollback(:not_hold_owner)
    end
  end

  defp require_idle!(scope) do
    running =
      Repo.exists?(
        from(r in Run, where: r.project_id == ^scope.active_project_id and r.status == :running)
      )

    if running, do: Repo.rollback(:execution_or_promotion_active)
    require_no_promotion!(scope)
  end

  defp require_no_promotion!(scope) do
    gating =
      Repo.exists?(
        from(e in "promotion_queue_entries",
          where:
            e.project_id == type(^scope.active_project_id, :binary_id) and e.status == "gating"
        )
      )

    if gating, do: Repo.rollback(:execution_or_promotion_active)
  end

  def open(project_id),
    do:
      Repo.one(
        from(h in ValidationHold, where: h.project_id == ^project_id and h.status != :released)
      )

  # Called within RunsRepository's transaction, before a row can be dispatched.
  def admit!(scope, attrs) do
    case open(scope.active_project_id) do
      nil ->
        nil

      %ValidationHold{status: :authorized, authorized_copy_id: copy, source: source, args: args} =
          hold ->
        requested_args = get_in(attrs, [:args, "args"]) || []

        case {scope.active_working_copy_id, attrs[:source], requested_args} do
          {^copy, ^source, ^args} -> hold
          _ -> Repo.rollback({:validation_held, hold.id, hold.owner_agent_id, hold.reason})
        end

      hold ->
        Repo.rollback({:validation_held, hold.id, hold.owner_agent_id, hold.reason})
    end
  end

  def bind!(nil, _run), do: :ok

  def bind!(hold, run),
    do: hold |> ValidationHold.changeset(%{status: :running, run_id: run.id}) |> persist!()

  def promotion_allowed?(project_id), do: is_nil(open(project_id))

  def terminal(run) do
    scope = %Scope{active_project_id: run.project_id}

    transaction(scope, fn ->
      case Repo.one(
             from(h in ValidationHold,
               where:
                 h.project_id == ^run.project_id and h.run_id == ^run.id and
                   h.status in [:running, :unknown]
             )
           ) do
        nil ->
          nil

        hold ->
          unknown? =
            run.orphaned or
              (run.status == :failed and is_nil(run.exit_status) and
                 get_in(run.stats || %{}, ["execution_terminal"]) != true)

          outcome = %{
            "run_id" => run.id,
            "status" => to_string(run.status),
            "exit_status" => run.exit_status,
            "execution_known" => not unknown?,
            "validation_passed" => run.status == :completed and run.exit_status == 0
          }

          hold
          |> ValidationHold.changeset(%{
            status: if(unknown?, do: :unknown, else: :awaiting_handoff),
            outcome: outcome
          })
          |> persist!()
      end
    end)
  end

  defp persist!(changeset) do
    case Repo.update(changeset) do
      {:ok, hold} -> hold
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp transaction(scope, fun) do
    result =
      Repo.transaction(fn ->
        lock(scope.active_project_id)

        case fun.() do
          %ValidationHold{} = hold ->
            event = %{
              "status" => to_string(hold.status),
              "at" => DateTime.to_iso8601(DateTime.utc_now()),
              "owner_agent_id" => hold.owner_agent_id,
              "authorized_copy_id" => hold.authorized_copy_id,
              "source" => hold.source,
              "args" => hold.args,
              "next_agent_id" => hold.next_agent_id,
              "run_id" => hold.run_id,
              "outcome" => hold.outcome
            }

            history = %{"events" => Map.get(hold.history || %{}, "events", []) ++ [event]}
            hold |> ValidationHold.changeset(%{history: history}) |> persist!()

          other ->
            other
        end
      end)

    case result do
      {:ok, %ValidationHold{} = hold} ->
        Phoenix.PubSub.broadcast(
          CodeMySpec.PubSub,
          "validation_holds:#{hold.project_id}",
          {:validation_hold, hold}
        )

        :telemetry.execute([:code_my_spec, :analysis, :validation_hold], %{}, %{
          scope: scope,
          hold: hold
        })

        result

      _ ->
        result
    end
  end
end
