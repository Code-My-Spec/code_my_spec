defmodule CodeMySpec.Workspaces do
  @moduledoc """
  One project's running instance.

  `boot/1` returns as soon as the instance has been accepted by the runner, not
  when it is up — coming up takes minutes, and the caller needs something to
  render immediately. The outcome arrives by broadcast, so a screen that
  subscribes learns both that it came up and that it didn't.

  Failure is a status, not an exception. A visitor whose workspace fails has to
  be told, and has to keep everything they had before it.
  """

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Workspaces.{Boot, BootSteps, Runner, Tracking, Workspace, WorkspacesRepository}

  @doc """
  Subscribes to a project's workspace.

  Broadcasts match:

    * {:booting, %Workspace{}}
    * {:progress, %Workspace{}}
    * {:running, %Workspace{}}
    * {:failed, %Workspace{}}

  """
  def subscribe_workspace(project_id) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic(project_id))
  end

  @spec get_workspace(Scope.t()) :: Workspace.t() | nil
  def get_workspace(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
    WorkspacesRepository.get_by_project(project_id)
  end

  def get_workspace(%Scope{}), do: nil

  @doc "Where to look at it, or nil while it is still coming up or has failed."
  @spec url(Workspace.t()) :: String.t() | nil
  def url(%Workspace{} = workspace), do: Workspace.url(workspace)

  @doc """
  Brings up the instance for the scope's active project.

  Returns a `:booting` workspace once the runner has accepted it. A workspace
  that is already running is returned as-is rather than started twice.
  """
  @spec boot(Scope.t()) :: {:ok, Workspace.t()} | {:error, term()}
  def boot(%Scope{active_project: %Project{} = project} = scope) do
    scope
    |> get_workspace()
    |> boot_workspace(project)
  end

  defp boot_workspace(%Workspace{status: :running} = workspace, _project), do: {:ok, workspace}

  defp boot_workspace(existing, %Project{} = project) do
    container_name = container_name(project)
    app_name = app_name(project)
    port = free_port()

    with :ok <- Runner.start(container_name, app_name, port),
         {:ok, workspace} <-
           WorkspacesRepository.upsert_booting(existing, %{
             project_id: project.id,
             container_name: container_name,
             port: port
           }) do
      Tracking.boot_started(workspace)
      broadcast(workspace, :booting)
      watch(workspace)
      {:ok, workspace}
    end
  end

  @doc "The workspace as it stands now, or nil if it has gone away."
  @spec reload(Workspace.t()) :: Workspace.t() | nil
  def reload(%Workspace{id: id}), do: WorkspacesRepository.get(id)

  @doc "Records the boot phase the container last announced, and tells anyone watching."
  @spec mark_step(Workspace.t(), BootSteps.step()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def mark_step(%Workspace{} = workspace, step) do
    with {:ok, workspace} <-
           workspace |> Workspace.step_changeset(step) |> WorkspacesRepository.update() do
      Tracking.step(workspace)
      broadcast(workspace, :progress)
      {:ok, workspace}
    end
  end

  @doc "How far along the boot is, as a percentage, for a progress bar."
  @spec progress(Workspace.t()) :: non_neg_integer()
  def progress(%Workspace{status: :running}), do: 100
  def progress(%Workspace{step: step}), do: BootSteps.percent(step)

  @doc "What the visitor is told is happening right now."
  @spec progress_label(Workspace.t()) :: String.t()
  def progress_label(%Workspace{status: :running}), do: "Running"
  def progress_label(%Workspace{step: step}), do: BootSteps.label(step)

  @doc "Records that the instance came up."
  @spec mark_running(Workspace.t()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(%Workspace{} = workspace) do
    with {:ok, workspace} <-
           workspace |> Workspace.running_changeset() |> WorkspacesRepository.update() do
      Tracking.running(workspace)
      broadcast(workspace, :running)
      {:ok, workspace}
    end
  end

  @doc "Records that it did not come up, with what the visitor gets told."
  @spec mark_failed(Workspace.t(), String.t()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def mark_failed(%Workspace{} = workspace, error) do
    with {:ok, workspace} <-
           workspace |> Workspace.failed_changeset(error) |> WorkspacesRepository.update() do
      Tracking.failed(workspace)
      broadcast(workspace, :failed)
      {:ok, workspace}
    end
  end

  @doc "Records that the visitor left while it was still coming up."
  @spec abandoned(Workspace.t()) :: :ok
  def abandoned(%Workspace{} = workspace), do: Tracking.abandoned(workspace)

  @doc "Tears the instance down. Setup's counterpart, used by tests and teardown."
  @spec stop(Workspace.t()) :: :ok
  def stop(%Workspace{container_name: name}) when is_binary(name), do: Runner.stop(name)
  def stop(%Workspace{}), do: :ok

  defp watch(%Workspace{} = workspace) do
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn -> Boot.watch(workspace) end)
  end

  defp broadcast(%Workspace{} = workspace, event) do
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, topic(workspace.project_id), {event, workspace})
  end

  defp topic(project_id), do: "project:#{project_id}:workspace"

  defp container_name(%Project{id: id}), do: "cms-workspace-#{id}"

  # `mix cms.new` wants an OTP application name, so the project's own name has
  # to survive being one.
  defp app_name(%Project{name: name}) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> prefix_if_leading_digit()
  end

  defp prefix_if_leading_digit(<<digit::utf8, _rest::binary>> = name) when digit in ?0..?9,
    do: "app_" <> name

  defp prefix_if_leading_digit(""), do: "app"
  defp prefix_if_leading_digit(name), do: name

  # Let the OS pick a free port, then hand it straight to the runner. A TOCTOU
  # race here surfaces as a failed boot, which is already a state we handle.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
