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

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Analytics,
      CodeMySpec.Content,
      CodeMySpec.Devices,
      CodeMySpec.Environments,
      CodeMySpec.Events,
      CodeMySpec.Projects,
      CodeMySpec.PublicUrl,
      CodeMySpec.Repo,
      CodeMySpec.Users,
      CodeMySpec.WorkingCopies
    ],
    exports: :all

  alias CodeMySpec.Devices
  alias CodeMySpec.Projects
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
  def boot(%Scope{active_project: %Project{}} = scope) do
    scope
    |> get_workspace()
    |> boot_workspace(scope)
  end

  # A stored `:running` is a claim about a container that may no longer exist —
  # a prune, a host reboot or a teardown removes the instance and leaves the
  # row behind. Trusting it showed the visitor "It's running" over a link that
  # refused the connection, so the claim is checked before it is repeated.
  defp boot_workspace(%Workspace{status: :running} = workspace, scope) do
    if still_serving?(workspace), do: {:ok, workspace}, else: start_instance(workspace, scope)
  end

  # One page view calls this twice — LiveView mounts disconnected, then again
  # over the socket — and each call used to take a fresh port and start the
  # container again, leaving the row pointing at the second instance and two
  # watchers polling for it. An instance that is already coming up is the
  # answer to "bring one up", so only a `:booting` row with nothing behind it
  # starts anything.
  defp boot_workspace(%Workspace{status: :booting} = workspace, scope) do
    if Runner.alive?(workspace.container_name),
      do: {:ok, workspace},
      else: start_instance(workspace, scope)
  end

  defp boot_workspace(existing, %Scope{} = scope), do: start_instance(existing, scope)

  defp still_serving?(%Workspace{container_name: name, port: port})
       when is_binary(name) and is_integer(port) do
    Runner.alive?(name) and Runner.healthy?(port)
  end

  defp still_serving?(%Workspace{}), do: false

  defp start_instance(existing, %Scope{active_project: %Project{} = project} = scope) do
    container_name = container_name(project)
    app_name = app_name(project)
    port = free_port()

    with :ok <- Runner.start(container_name, app_name, port, instance_env(scope)),
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
  # Takes the caller's scope rather than building one from the project, because
  # minting the deploy key is a write and a scope with no account cannot make
  # one. The synthesised scope was enough while this only read.
  defp instance_env(%Scope{active_project: %Project{} = project} = scope) do
    label = "the cloud copy of #{project.name}"

    with {:ok, project} <- Projects.ensure_deploy_key(scope, project),
         scope = %Scope{scope | active_project: project, active_project_id: project.id},
         {:ok, device} <- cloud_device(scope, project),
         {:ok, copy} <-
           WorkingCopies.issue(scope, existing_cloud_copy(scope, project),
             label: label,
             device: device
           ),
         # Where it will be, said now rather than waited for. A row is not a
         # checkout until it says where it is, and only a rooted copy can be the
         # project's main one — which is what the preview endpoint requires
         # before it will provision anything.
         #
         # The server knows the path because the server chose it: the entrypoint
         # generates into `/workspace/<app>` and nowhere else. Waiting for the
         # instance to report it instead is what left the copy rootless, never
         # main and never previewed — the harness picks a copy up on its first
         # hook request, and an instance a visitor is merely watching never makes
         # one.
         {:ok, copy} <- WorkingCopies.report_root(copy, instance_root(project)) do
      [{"CMS_WORKING_COPY_ID", copy.id}, {"CMS_PROJECT_ID", project.id}] ++
        deploy_key_env(project) ++ server_url_env()
    else
      {:error, reason} ->
        # Not fatal. An instance that comes up un-onboarded still runs the
        # application, which is most of what the visitor came for — and saying
        # so beats refusing to start one at all.
        Logger.warning("[Workspaces] could not issue a working copy: #{inspect(reason)}")
        []
    end
  end

  # The copy this project's cloud instance already has, if it has one.
  #
  # Booting replaces the container -- `Runner.start/4` removes whatever was
  # there first -- so an instance that has gone down and been brought back is
  # the same working copy at the same root, not a second one. Minting a fresh
  # copy each time was visible: a workspace that crashed and was retried came
  # back with a copy that was not the project's main one, and only the main copy
  # is given a preview. The visitor's rebuilt project could never get an
  # address, while the address on their screen belonged to the copy that no
  # longer existed and answered 530.
  #
  # Matched on the root because that is what identifies a checkout, and the root
  # is ours to know: the entrypoint generates into `/workspace/<app>` and
  # nowhere else. `recognised/3` inside `issue/3` cannot do this for us -- it
  # needs a device, and a cloud instance has none until its harness joins, which
  # is after this runs.
  # The machine a cloud copy is on, which is not anybody's laptop.
  #
  # A seen `working_copies` row must name its device — the check constraint is
  # `device_id IS NOT NULL OR last_seen_at IS NULL`, not a plain NOT NULL — and a
  # cloud copy is seen the moment it connects. A checkout is identified by
  # {project, device, root}, and `/workspace/<app>` is a path every container
  # shares, so without a device two visitors' instances are one indistinguishable
  # row. This is also the only place `kind: :cloud` is written from, and it is
  # what will let an agent on this copy know it may not spend a subscription:
  # the providers do not license one for a server running agents on somebody's
  # behalf, so a cloud copy's agent needs an API key.
  #
  # One device per project, not one per boot. `announce/3` recognises by
  # `{account, device_id}` and this has no id to present, so announcing on every
  # boot would mint a row every time a visitor restarted their workspace — the
  # duplicate the working-copy lookup exists to prevent, one table over. The
  # copy that is already there is what remembers which machine it was, so it is
  # asked first.
  defp cloud_device(scope, %Project{} = project) do
    case device_of_existing_cloud_copy(scope, project) do
      nil -> Devices.announce(scope, nil, %{hostname: "cloud-#{project.id}", kind: :cloud})
      device_id -> {:ok, device_id}
    end
  end

  defp device_of_existing_cloud_copy(scope, %Project{} = project) do
    root = instance_root(project)

    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.find(&(&1.root == root))
    |> case do
      %{device_id: device_id} when is_binary(device_id) -> device_id
      _ -> nil
    end
  end

  defp existing_cloud_copy(scope, %Project{} = project) do
    root = instance_root(project)

    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.find(&(&1.root == root))
    |> case do
      nil -> nil
      copy -> copy.id
    end
  end

  # Where the entrypoint puts it. One place decides this and it is not the
  # instance: `docker/devbox/entrypoint.sh` generates into `/workspace/$APP_NAME`
  # and nowhere else.
  defp instance_root(%Project{} = project), do: "/workspace/#{app_name(project)}"

  # The instance's only credential. `ensure_deploy_key/2` is what makes this
  # clause reachable: nothing mints a key at project creation, so a project
  # made through intake had none, and an instance handed no key could not
  # authenticate to ask for its own preview. It came up and served, which is
  # why that went unnoticed.
  defp deploy_key_env(%Project{deploy_key: key}) when is_binary(key) and key != "",
    do: [{"CMS_DEPLOY_KEY", key}]

  defp deploy_key_env(_project), do: []

  # Where the instance's harness reports back to.
  #
  # Without it the harness joins whatever URL it was compiled with, which is
  # production — so a container a developer started would announce its working
  # copy to the live server, and the copy the visitor is waiting to see would
  # never appear here.
  #
  # Configured rather than derived, because the answer is a property of where
  # the instance runs rather than of this server: inside a container
  # `localhost:4000` is the container, so the host has to be named the way the
  # container can actually reach it.
  defp server_url_env do
    :code_my_spec
    |> Application.get_env(CodeMySpec.Workspaces, [])
    |> Keyword.get(:server_url)
    |> case do
      url when is_binary(url) and url != "" -> [{"CMS_SERVER_URL", url}]
      _ -> []
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
