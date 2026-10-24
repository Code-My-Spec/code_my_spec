defmodule CodeMySpec.Promotion.DeviceSync do
  @moduledoc "Durable application of a published revision on the project's main device."

  import Ecto.Query
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Promotion
  alias CodeMySpec.Promotion.Runner
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Repo.SandboxAllowance
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.{AppTransport, WorkingCopy}

  @timeout 600_000

  @doc "Reserve a durable publication order before publishing; the queue stores it with the receipt identity."
  def reserve_sequence(%Scope{} = scope) do
    safely(fn ->
      Repo.transaction(fn ->
        project = locked_project(scope)
        sequence = project.publication_sequence + 1
        save!(Ecto.Changeset.change(project, publication_sequence: sequence))
        sequence
      end)
    end)
  end

  @doc "Record the desired revision before dispatching any work. Offline is pending, not failed publication."
  def request(%Scope{} = scope, head, branch, promotion_id, opts \\ []) do
    desired = %{
      "status" => "pending",
      "head" => head,
      "branch" => branch,
      "promotion_id" => promotion_id,
      "restart" => Keyword.get(opts, :restart, false),
      "requested_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    safely(fn ->
      with {:ok, stored} <- persist_intent(scope, desired, opts) do
        request_copy(scope, stored, opts)
      end
    end)
  end

  defp persist_intent(scope, desired, opts) do
    Repo.transaction(fn ->
      project = locked_project(scope)
      current = project.promotion_sync || %{}
      sequence = Keyword.get(opts, :publication_sequence) || project.publication_sequence + 1

      cond do
        same_request?(current, desired) ->
          current

        sequence <= Map.get(current, "publication_sequence", 0) ->
          current

        true ->
          desired = Map.put(desired, "publication_sequence", sequence)

          project
          |> Ecto.Changeset.change(
            promotion_sync: desired,
            publication_sequence: max(sequence, project.publication_sequence)
          )
          |> save!()

          desired
      end
    end)
  end

  defp locked_project(scope) do
    Repo.lock!("promotion-intent:#{scope.active_project_id}")
    Repo.get(Project, scope.active_project_id) || Repo.rollback(:project_not_found)
  end

  defp save!(changeset) do
    case Repo.update(changeset) do
      {:ok, value} -> value
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, {:device_sync_persistence_failed, Exception.message(error)}}
  end

  defp request_copy(scope, desired, opts) do
    case WorkingCopies.main(scope) do
      nil ->
        {:ok, Map.put(desired, "reason", "no main device registered")}

      copy ->
        result =
          Repo.transaction(fn ->
            Repo.lock!("promotion-device-sync:#{copy.id}")
            fresh = Repo.get!(WorkingCopy, copy.id)
            state = fresh.promotion_sync || %{}
            # Reconnect may have read an older request just before the next
            # publication. Always seed from the latest durable project intent.
            desired = Repo.get!(Project, scope.active_project_id).promotion_sync

            if state["promotion_id"] == desired["promotion_id"] and
                 state["head"] == desired["head"] do
              state
            else
              fresh |> Ecto.Changeset.change(promotion_sync: desired) |> Repo.update!()
              desired
            end
          end)

        if match?({:ok, _}, result), do: schedule(scope, copy.id, opts)
        result
    end
  end

  @doc "Retry application of a durable published revision without republishing the candidate."
  def retry(%Scope{} = scope, id) do
    safely(fn ->
      with {:ok, %WorkingCopy{main: true, project_id: project_id}} <- WorkingCopies.fetch(id),
           true <- project_id == scope.active_project_id,
           %{"head" => _} = desired <- Repo.get!(Project, project_id).promotion_sync do
        with {:ok, _} <- reset_failed(id), do: request_copy(scope, desired, [])
      else
        _ -> {:error, :no_published_revision_for_destination}
      end
    end)
  end

  defp reset_failed(id) do
    Repo.transaction(fn ->
      Repo.lock!("promotion-device-sync:#{id}")
      copy = Repo.get!(WorkingCopy, id)
      state = copy.promotion_sync || %{}

      if state["status"] == "failed" do
        copy
        |> Ecto.Changeset.change(
          promotion_sync: Map.merge(state, %{"status" => "pending", "error" => nil})
        )
        |> save!()
      end
    end)
  end

  @doc "Resume durable device work after a channel reconnect."
  def copy_joined(scope, %WorkingCopy{main: true}) do
    case Repo.get!(Project, scope.active_project_id).promotion_sync do
      %{"head" => _} = desired -> request_copy(scope, desired, [])
      _ -> :ok
    end

    :ok
  end

  def copy_joined(_scope, _copy), do: :ok

  @doc "Resume work left pending by a server restart."
  def resume_all do
    for copy <- Repo.all(from c in WorkingCopy, where: c.main == true) do
      copy_joined(%Scope{active_project_id: copy.project_id}, copy)
    end

    :ok
  end

  defp schedule(scope, id, opts) do
    if Keyword.get(opts, :dispatch, true) and connected?(id) do
      owners = SandboxAllowance.owners()

      Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
        SandboxAllowance.take(owners)
        apply_pending(scope, id, opts)
      end)
    end

    :ok
  end

  defp connected?(id), do: match?({:ok, _, _}, HarnessRegistry.executor_holder(id))

  @doc "Apply the latest desired revision. Completed receipts are never executed again."
  def apply_pending(scope, id, opts \\ []) do
    :global.trans({{__MODULE__, id}, self()}, fn ->
      copy = Repo.get!(WorkingCopy, id)

      case copy.promotion_sync do
        %{"status" => status} = desired when status in ["pending", "failed"] ->
          outcome = apply_revision(scope, copy, desired, opts)
          record(copy.id, desired, outcome)

        other ->
          {:ok, other}
      end
    end)
  end

  defp apply_revision(scope, copy, desired, opts) do
    sync = Keyword.get(opts, :sync, &Runner.remote_sync/5)
    app = Keyword.get(opts, :app, AppTransport)
    scoped = %{scope | active_working_copy_id: copy.id}

    with {:ok, changed} <-
           sync.(
             WorkingCopies.environment(scoped),
             copy.root,
             copy.id,
             desired["branch"],
             desired["head"]
           ) do
      changed_files = desired["changed_files"] || Map.get(changed, :changed_files)
      checkpoint(copy.id, desired, changed_files)
      # A restart may have completed and lost its reply. Verify before
      # reissuing lifecycle work (including the after-promote recipe).
      current = app.ensure_app_running(copy.id, @timeout)

      if serving?(current, desired["head"]) do
        {:ok, desired["head"]}
      else
        plan =
          Promotion.deployment_plan(changed_files,
            restart: desired["restart"],
            reload_supported: app.reload_supported?(copy.id)
          )

        result =
          case plan.action do
            :restart -> app.restart_app(copy.id, @timeout)
            :reload -> app.reload_app(copy.id, @timeout)
          end

        if serving?(result, desired["head"]) do
          {:ok, desired["head"]}
        else
          verify = app.ensure_app_running(copy.id, @timeout)

          if serving?(verify, desired["head"]),
            do: {:ok, desired["head"]},
            else: {:error, {:app_revision_unconfirmed, result, verify}}
        end
      end
    end
  end

  defp serving?({:ok, info}, head) do
    Map.get(info, :status) in ["serving", :serving, "erroring", :erroring] and
      (Map.get(info, :serving_commit) || Map.get(info, :commit)) == head
  end

  defp serving?(_, _), do: false

  defp checkpoint(id, desired, changed_files) do
    Repo.transaction(fn ->
      Repo.lock!("promotion-device-sync:#{id}")
      copy = Repo.get!(WorkingCopy, id)

      if same_request?(copy.promotion_sync, desired) do
        copy
        |> Ecto.Changeset.change(
          promotion_sync: Map.put(copy.promotion_sync, "changed_files", changed_files)
        )
        |> Repo.update!()
      end
    end)
  end

  defp same_request?(left, right),
    do: left["promotion_id"] == right["promotion_id"] and left["head"] == right["head"]

  defp record(id, desired, result) do
    Repo.transaction(fn ->
      Repo.lock!("promotion-device-sync:#{id}")
      copy = Repo.get!(WorkingCopy, id)

      if same_request?(copy.promotion_sync, desired) do
        desired = copy.promotion_sync

        state =
          case result do
            {:ok, head} ->
              Map.merge(desired, %{
                "status" => "applied",
                "applied_commit" => head,
                "applied_at" => DateTime.to_iso8601(DateTime.utc_now()),
                "error" => nil
              })

            {:error, reason} ->
              Map.merge(desired, %{"status" => "failed", "error" => inspect(reason)})
          end

        copy |> Ecto.Changeset.change(promotion_sync: state) |> Repo.update!()
        state
      else
        copy.promotion_sync
      end
    end)
  end
end
