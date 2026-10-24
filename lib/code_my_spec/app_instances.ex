defmodule CodeMySpec.AppInstances do
  @moduledoc "Runtime instances associated with project source checkouts."
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Devices,
      CodeMySpec.Analysis.HarnessRegistry,
      CodeMySpec.Encrypted.Binary,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  import Ecto.Query, except: [update: 3], warn: false
  alias CodeMySpec.AppInstances.AppInstance
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  def ensure_default(%Scope{active_project_id: project_id}, copy) when is_map(copy) do
    copy_id = value(copy, :id)
    root = value(copy, :root)
    copy_project_id = value(copy, :project_id)

    if is_binary(project_id) and copy_project_id == project_id and is_binary(copy_id) and
         (is_nil(root) or (is_binary(root) and root != "")) do
      case for_working_copy(%Scope{active_project_id: project_id}, copy_id) do
        nil ->
          main = value(copy, :main) == true

          attrs = %{
            project_id: project_id,
            device_id: value(copy, :device_id),
            working_copy_id: copy_id,
            source_root: root,
            default: true,
            persistent: main,
            after_promote: main,
            port_mode: if(main, do: :configured, else: :allocated),
            database_mode: if(main, do: :configured, else: :clone),
            promotion_sync: value(copy, :promotion_sync) || %{}
          }

          case create(%Scope{active_project_id: project_id}, attrs) do
            {:error, %Ecto.Changeset{} = changeset} ->
              if Enum.any?(changeset.errors, fn {_field, {_message, meta}} ->
                   meta[:constraint] == :unique or
                     meta[:constraint_name] == :app_instances_one_default_per_source_index
                 end) do
                case for_working_copy(%Scope{active_project_id: project_id}, copy_id) do
                  nil ->
                    {:error, changeset}

                  instance ->
                    refresh_source(
                      %Scope{active_project_id: project_id},
                      instance,
                      root,
                      value(copy, :device_id)
                    )
                end
              else
                {:error, changeset}
              end

            result ->
              result
          end

        instance ->
          refresh_source(
            %Scope{active_project_id: project_id},
            instance,
            root,
            value(copy, :device_id)
          )
      end
    else
      {:error, :invalid_source}
    end
  end

  def ensure_default(_, _), do: {:error, :invalid_scope}

  def for_working_copy(%Scope{active_project_id: project_id}, copy) when is_binary(project_id) do
    id = value(copy, :id) || copy

    if is_binary(id),
      do:
        Repo.one(
          from(i in AppInstance,
            where: i.project_id == ^project_id and i.working_copy_id == ^id and i.default == true
          )
        ),
      else: nil
  end

  def for_working_copy(_, _), do: nil

  def get(%Scope{active_project_id: project_id}, id) when is_binary(project_id) and is_binary(id),
    do: Repo.one(from(i in AppInstance, where: i.project_id == ^project_id and i.id == ^id))

  def get(_, _), do: nil
  def get!(scope, id), do: get(scope, id) || raise(Ecto.NoResultsError, queryable: AppInstance)

  def list_for_working_copy(%Scope{active_project_id: project_id}, copy) do
    id = value(copy, :id) || copy

    Repo.all(
      from(i in AppInstance,
        where: i.project_id == ^project_id and i.working_copy_id == ^id,
        order_by: [asc: i.inserted_at]
      )
    )
  end

  def list_for_working_copy(_, _), do: []

  def create(%Scope{active_project_id: project_id}, attrs)
      when is_binary(project_id) and is_map(attrs) do
    requested_project = value(attrs, :project_id)
    attrs = put_value(attrs, :project_id, project_id)

    with true <- is_nil(requested_project) or requested_project == project_id,
         :ok <-
           validate_source(project_id, value(attrs, :working_copy_id), value(attrs, :device_id)) do
      %AppInstance{} |> AppInstance.changeset(attrs) |> Repo.insert()
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  def create(_, _), do: {:error, :invalid_scope}

  def update(%Scope{active_project_id: project_id} = scope, %AppInstance{id: id}, attrs)
      when is_binary(project_id) and is_map(attrs) do
    with %AppInstance{project_id: ^project_id} = instance <- get(scope, id),
         :ok <- storage_policy_change(instance, attrs),
         true <- same_or_omitted?(attrs, :project_id, project_id),
         true <- same_or_omitted?(attrs, :working_copy_id, instance.working_copy_id),
         true <- same_or_omitted?(attrs, :device_id, instance.device_id),
         true <- same_or_omitted?(attrs, :id, instance.id),
         :ok <- validate_source(project_id, instance.working_copy_id, instance.device_id) do
      attrs =
        attrs
        |> delete_value(:id)
        |> delete_value(:project_id)
        |> delete_value(:working_copy_id)
        |> delete_value(:device_id)

      instance |> AppInstance.changeset(attrs) |> Repo.update() |> announce_change(instance)
    else
      false -> {:error, :scope_mismatch}
      nil -> {:error, :not_found}
      %AppInstance{} -> {:error, :not_found}
      error -> error
    end
  end

  def update(_, _, _), do: {:error, :not_found}

  def record_status(scope, instance_or_id, info) when is_map(info) do
    status = value(info, :status)

    if status in ["serving", "erroring", "down", "starting"] do
      with %AppInstance{} = i <- resolve(scope, instance_or_id) do
        update(scope, i, %{
          status: status,
          checked_at: DateTime.utc_now(),
          url: if(status == "down", do: nil, else: value(info, :url) || i.url),
          commit: value(info, :commit) || i.commit,
          serving_commit: value(info, :serving_commit) || value(info, :commit) || i.serving_commit
        })
      else
        _ -> {:error, :not_found}
      end
    else
      {:error, :invalid_status}
    end
  end

  def record_status(_, _, _), do: {:error, :invalid_status}

  def record_preview_status(scope, id, status) when status in ["serving", "erroring", "down"] do
    case resolve(scope, id) do
      %AppInstance{} = instance ->
        update(scope, instance, %{preview_status: status, preview_checked_at: DateTime.utc_now()})

      nil ->
        {:error, :not_found}
    end
  end

  def record_preview_status(_, _, _), do: {:error, :invalid_status}

  def record_preview_tunnel(scope, id, attrs) do
    case resolve(scope, id) do
      %AppInstance{} = instance ->
        update(
          scope,
          instance,
          Map.take(attrs, [:preview_url, :preview_tunnel_id, :preview_tunnel_secret])
        )

      nil ->
        {:error, :not_found}
    end
  end

  def clear_preview_tunnel(scope, id),
    do:
      record_preview_tunnel(scope, id, %{
        preview_url: nil,
        preview_tunnel_id: nil,
        preview_tunnel_secret: nil
      })

  def delete(scope, id) do
    with %AppInstance{status: status} = i <- resolve(scope, id),
         true <- status in [nil, "down"] do
      Repo.delete(i)
    else
      false -> {:error, :instance_running}
      nil -> {:error, :not_found}
    end
  end

  def descriptor(%AppInstance{} = i), do: descriptor(Map.from_struct(i))

  def descriptor(i) when is_map(i),
    do: %{
      "instance_id" => value(i, :id),
      "working_copy_id" => value(i, :working_copy_id),
      "default" => value(i, :default),
      "root" => value(i, :source_root),
      "persistent" => value(i, :persistent),
      "port_mode" => enum(value(i, :port_mode)),
      "database_mode" => enum(value(i, :database_mode)),
      "database_source" => value(i, :database_source),
      "after_promote" => value(i, :after_promote)
    }

  def ensure_running(scope, id, timeout \\ 600_000),
    do: lifecycle(scope, id, :ensure_app_running, timeout, :start_timed_out)

  def restart(scope, id, timeout \\ 600_000),
    do: lifecycle(scope, id, :restart_app, timeout, :restart_timed_out)

  def reload(scope, id, timeout \\ 600_000),
    do: lifecycle(scope, id, :reload_app, timeout, :reload_timed_out)

  def stop(scope, id, timeout \\ 600_000),
    do: lifecycle(scope, id, :stop_app, timeout, :stop_timed_out)

  @doc "Discard the instance's process and disposable runtime artifacts on its device."
  def discard(scope, id, timeout \\ 600_000),
    do: lifecycle(scope, id, :discard_app, timeout, :discard_timed_out)

  def reload_supported?(scope, id),
    do:
      with(
        %AppInstance{working_copy_id: copy_id} <- get(scope, id),
        do: CodeMySpec.Analysis.HarnessRegistry.supports?(copy_id, "reload_app"),
        else: (_ -> false)
      )

  def qa_revision_check(info) when is_map(info) do
    serving = value(info, :serving_commit) || value(info, :commit)
    head = value(info, :head)

    if is_binary(serving) and serving != "" and serving == head do
      :ok
    else
      {:error,
       "Do not test against this app yet. Served revision: #{serving || "unknown"}; checkout HEAD: #{head || "unknown"}. QA requires matching revisions. Use restart_app for this instance, then call ensure_app_running to verify the revision before testing. Do not start another restart while one is running."}
    end
  end

  def first_start_inline_window_ms,
    do:
      Application.get_env(:code_my_spec, :app_instance_first_start_probe_attempts, 30) *
        Application.get_env(:code_my_spec, :app_instance_health_wait_interval_ms, 1_000)

  def call_grace_ms, do: Application.get_env(:code_my_spec, :call_grace_ms, 5_000)

  defp lifecycle(scope, id, verb, timeout, _timeout_reason) do
    with %AppInstance{} = i <- get(scope, id) do
      result = CodeMySpec.AppInstances.Transport.request(i, verb, timeout)

      case result do
        {:ok, info} when is_map(info) ->
          case reply_for_instance(info, i.id) do
            {:ok, info} ->
              case record_status(scope, i, info) do
                {:ok, _updated} -> {:ok, info}
                error -> error
              end

            error ->
              error
          end

        :ok when verb in [:stop_app, :discard_app] ->
          case record_status(scope, i, %{status: "down"}) do
            {:ok, _} -> :ok
            error -> error
          end

        other ->
          other
      end
    else
      nil -> {:error, :not_found}
    end
  end

  defp reply_for_instance(info, id) do
    reported_id = value(info, :instance_id)

    cond do
      is_binary(reported_id) and reported_id != id -> {:error, :instance_mismatch}
      Map.has_key?(info, "instance_id") -> {:ok, Map.put_new(info, "instance_id", id)}
      true -> {:ok, Map.put_new(info, :instance_id, id)}
    end
  end

  defp refresh_source(scope, instance, root, device_id) do
    with :ok <- validate_source(scope.active_project_id, instance.working_copy_id, device_id) do
      attrs = [device_id: device_id]

      attrs = if is_binary(root), do: Keyword.put(attrs, :source_root, root), else: attrs

      instance
      |> Ecto.Changeset.change(attrs)
      |> Repo.update()
    end
  end

  defp announce_change({:ok, updated} = result, before) do
    if Enum.any?([:preview_status, :preview_url], &(Map.get(before, &1) != Map.get(updated, &1))) do
      CodeMySpec.Requirements.GraphInputs.announce(
        updated.project_id,
        "AppInstances",
        [],
        :project_wide
      )
    end

    result
  end

  defp announce_change(result, _before), do: result

  defp resolve(scope, %AppInstance{id: id}), do: get(scope, id)
  defp resolve(scope, id), do: get(scope, id)

  defp validate_source(project_id, nil, device_id) do
    with %Project{account_id: account_id} <- Repo.get(Project, project_id),
         :ok <- validate_device_account(device_id, account_id) do
      :ok
    else
      nil -> {:error, :project_not_found}
      error -> error
    end
  end

  defp validate_source(project_id, working_copy_id, device_id) do
    source =
      Repo.one(
        from(w in "working_copies",
          where: field(w, :id) == type(^working_copy_id, :binary_id),
          select: %{
            project_id: type(field(w, :project_id), :binary_id),
            device_id: type(field(w, :device_id), :binary_id)
          }
        )
      )

    case source do
      %{project_id: ^project_id, device_id: ^device_id} ->
        :ok

      nil ->
        {:error, :working_copy_not_found}

      _ ->
        {:error, :working_copy_scope_mismatch}
    end
  end

  defp validate_device_account(nil, _account_id), do: :ok

  defp validate_device_account(device_id, account_id) do
    case Repo.get(Device, device_id) do
      %Device{account_id: ^account_id} -> :ok
      nil -> {:error, :device_not_found}
      _ -> {:error, :device_account_mismatch}
    end
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp value(_, _), do: nil

  # Reclassifying a configured database as disposable would make discard unsafe.
  # Reallocation needs its own explicit operation; this context does not provide one.
  defp storage_policy_change(%AppInstance{checked_at: nil}, _attrs), do: :ok

  defp storage_policy_change(instance, attrs) do
    changed? =
      Enum.any?([:port_mode, :database_mode, :database_source], fn key ->
        supplied = value(attrs, key)
        present? = Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
        present? and enum(supplied) != enum(Map.get(instance, key))
      end)

    if changed?, do: {:error, :instance_storage_policy_in_use}, else: :ok
  end

  defp same_or_omitted?(map, key, expected) do
    (not Map.has_key?(map, key) and not Map.has_key?(map, Atom.to_string(key))) or
      value(map, key) == expected
  end

  defp put_value(map, key, value) do
    if Map.has_key?(map, Atom.to_string(key)),
      do: Map.put(map, Atom.to_string(key), value),
      else: Map.put(map, key, value)
  end

  defp delete_value(map, key), do: Map.delete(Map.delete(map, key), Atom.to_string(key))
  defp enum(nil), do: nil
  defp enum(v) when is_atom(v), do: Atom.to_string(v)
  defp enum(v), do: v
end
