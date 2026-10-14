defmodule CodeMySpecWeb.AppLive.DesktopProject do
  @moduledoc "Registers a desktop-selected checkout using existing account and copy APIs."

  alias CodeMySpec.{Accounts, Devices, Projects, UserPreferences, WorkingCopies}
  alias CmsHarness.{HarnessConfig, ProjectIdentity, Setup}

  def connect(scope, path, device_id) when is_binary(device_id) and device_id != "" do
    with :ok <- desktop_only(),
         {:ok, snapshot} <- Setup.status(),
         true <- Setup.prerequisites_passed?(snapshot),
         {:ok, root} <- Setup.Project.validate(path) do
      case :global.trans(
             {{__MODULE__, root}, self()},
             fn ->
               register(scope, root, device_id)
             end,
             [node()],
             0
           ) do
        :aborted -> {:error, :project_registration_busy}
        result -> result
      end
    else
      :none -> {:error, :prerequisites_not_checked}
      false -> {:error, :prerequisites_failed}
      {:error, _} = error -> error
    end
  end

  def connect(_scope, _path, _device_id), do: {:error, :device_identity_unavailable}

  defp register(scope, root, device_id) do
    with :ok <- compatible_server(root),
         {:ok, scope} <- account_scope(scope),
         {:ok, project} <- selected_project(scope, root),
         project_scope = %{scope | active_project: project, active_project_id: project.id},
         {:ok, device} <- Devices.announce(project_scope, device_id, %{kind: :local}),
         {:ok, copy_id} <- recorded_copy(root),
         {:ok, copy} <- WorkingCopies.issue(project_scope, copy_id, device: device.id, root: root),
         {:ok, copy} <- WorkingCopies.report_root(copy, root),
         :ok <- designate_if_needed(project_scope, copy.id),
         {:ok, snapshot} <-
           Setup.connect_project(
             root,
             %{
               project_id: project.id,
               working_copy_id: copy.id,
               app: Path.basename(root)
             },
             []
           ) do
      {:ok, %{project: project, working_copy: copy, snapshot: snapshot, scope: project_scope}}
    end
  end

  defp account_scope(%{active_account_id: id} = scope) when is_binary(id), do: {:ok, scope}

  defp account_scope(scope) do
    with {:ok, account} <- existing_or_local_account(scope),
         {:ok, _} <- UserPreferences.select_active_account(scope, account.id) do
      {:ok, UserPreferences.scope_for(scope.user)}
    end
  end

  defp existing_or_local_account(scope) do
    case Accounts.list_accounts(scope) do
      [account | _] -> {:ok, account}
      [] -> Accounts.create_account(scope, %{name: "Local"})
    end
  end

  defp selected_project(scope, root) do
    case ProjectIdentity.resolve(root) do
      {:ok, %{id: id}} -> Projects.get_project(scope, id)
      {:error, :no_project_id} -> existing_or_new_project(scope, root)
      {:error, _} = error -> error
    end
  end

  defp existing_or_new_project(scope, root) do
    case Enum.find(Projects.list_projects(scope), &(&1.local_path == root)) do
      nil ->
        name = Path.basename(root)
        module_name = name |> String.replace(~r/[^a-zA-Z0-9_]/, "_") |> Macro.camelize()
        Projects.create_project(scope, %{name: name, module_name: module_name, local_path: root})

      project ->
        {:ok, project}
    end
  end

  defp compatible_server(root) do
    expected = CmsHarness.Config.server_url()

    case HarnessConfig.read_file(root) do
      :none -> :ok
      {:ok, %{server_url: nil}} -> :ok
      {:ok, %{server_url: ^expected}} -> :ok
      {:ok, %{server_url: other}} -> {:error, {:server_identity_conflict, other}}
      {:error, _} = error -> error
    end
  end

  defp recorded_copy(root) do
    case HarnessConfig.read_file(root) do
      :none -> {:ok, nil}
      {:ok, config} -> {:ok, config.working_copy_id}
      {:error, _} = error -> error
    end
  end

  defp designate_if_needed(scope, copy_id) do
    case WorkingCopies.main(scope) do
      nil ->
        case WorkingCopies.designate_main(scope, copy_id) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      _existing ->
        :ok
    end
  end

  defp desktop_only do
    if Application.get_env(:code_my_spec, :env) == :desktop,
      do: :ok,
      else: {:error, :desktop_only}
  end
end
