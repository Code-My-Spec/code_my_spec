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
  require Logger

  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
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
  What the app is doing right now, asked rather than inferred.

  The pane cannot work this out from the proxy's answer: a booting container
  and a crashed one both fail to reply, and an app raising on every request
  replies just as readily as a healthy one. Those are three different things
  to tell Sam — wait, we broke it, you broke it — so they are three states.

  `:starting` is ours and is read off the stored step. `:broken` is the app's
  own doing. `:down` is an instance that is not there.
  """
  @spec state(Workspace.t()) :: :starting | :running | :broken | :down
  def state(%Workspace{status: :failed}), do: :down
  def state(%Workspace{status: :booting}), do: :starting

  def state(%Workspace{container_name: name, port: port})
      when is_binary(name) and is_integer(port) do
    if Runner.alive?(name), do: from_serving(Runner.serving(port)), else: :down
  end

  def state(%Workspace{}), do: :down

  defp from_serving(:serving), do: :running
  defp from_serving(:erroring), do: :broken
  # Alive but answering nothing is still coming up — the container is there,
  # so this is the wait, not a failure.
  defp from_serving(:down), do: :starting

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

  # A stored `:running` is a claim about a container that may no longer exist —
  # a prune, a host reboot or a teardown removes the instance and leaves the
  # row behind. Trusting it showed the visitor "It's running" over a link that
  # refused the connection, so the claim is checked before it is repeated.
  defp boot_workspace(%Workspace{status: :running} = workspace, project) do
    case still_serving?(workspace) do
      true -> {:ok, workspace}
      false -> start_instance(workspace, project)
    end
  end

  # One page view calls this twice — LiveView mounts disconnected, then again
  # over the socket — and each call used to take a fresh port and start the
  # container again, leaving the row pointing at the second instance and two
  # watchers polling for it. An instance that is already coming up is the
  # answer to "bring one up", so only a `:booting` row with nothing behind it
  # starts anything.
  defp boot_workspace(%Workspace{status: :booting} = workspace, project) do
    case Runner.alive?(workspace.container_name) do
      true -> {:ok, workspace}
      false -> start_instance(workspace, project)
    end
  end

  defp boot_workspace(existing, %Project{} = project), do: start_instance(existing, project)

  defp still_serving?(%Workspace{container_name: name, port: port})
       when is_binary(name) and is_integer(port) do
    Runner.alive?(name) and Runner.healthy?(port)
  end

  defp still_serving?(%Workspace{}), do: false

  defp start_instance(existing, %Project{} = project) do
    container_name = container_name(project)
    app_name = app_name(project)
    port = free_port()

    with :ok <- Runner.start(container_name, app_name, port, instance_env(project)),
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

  # What the instance needs to know about itself.
  #
  # A container comes up holding an application and nothing else — no checkout
  # anybody onboarded, no identity, no credential. Handed these it can onboard
  # itself on the way up, which is what turns it from a directory that happens
  # to be running into a working copy the visitor owns: a row they can see, a
  # harness that joins, and a preview address provisioned the same way a
  # laptop's is.
  #
  # The id is minted here rather than inside, because minting needs the server
  # and the whole point of onboarding a copy is that it already has one. Same
  # reason `mix cms.harness.onboard` asks the server before it writes anything.
  defp instance_env(%Project{} = project) do
    scope = %Scope{active_project: project, active_project_id: project.id}

    case WorkingCopies.issue(scope, nil, label: "the cloud copy of #{project.name}") do
      {:ok, copy} ->
        [{"CMS_WORKING_COPY_ID", copy.id}, {"CMS_PROJECT_ID", project.id}] ++
          deploy_key_env(project)

      {:error, reason} ->
        # Not fatal. An instance that comes up un-onboarded still runs the
        # application, which is most of what the visitor came for — and saying
        # so beats refusing to start one at all.
        Logger.warning("[Workspaces] could not issue a working copy: #{inspect(reason)}")
        []
    end
  end

  defp deploy_key_env(%Project{deploy_key: key}) when is_binary(key) and key != "",
    do: [{"CMS_DEPLOY_KEY", key}]

  defp deploy_key_env(_project), do: []

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
