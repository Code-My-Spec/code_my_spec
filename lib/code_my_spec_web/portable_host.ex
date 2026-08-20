defmodule CodeMySpecWeb.PortableHost do
  @moduledoc """
  Supplies the cloud app's half of what a portable LiveView needs.

  The counterpart to `CodeMySpecLocalWeb.PortableHost` — same assign contract
  (`:scope`, `:project`, `:slug`, `:error`), resolved against the signed-in
  user's account instead of the filesystem.

  The project comes from the route rather than the session's active project,
  and the scope is amended in memory only, so following a link never rewrites
  a persisted preference.
  """

  use CodeMySpecWeb, :html

  import Phoenix.LiveView, only: [attach_hook: 4]

  alias CodeMySpec.Projects
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users.Scope

  def on_mount(:default, params, _session, socket) do
    if project_scoped?(params) do
      mount_project_scope(params, socket)
    else
      # A route in this live_session that doesn't name a project isn't ours to
      # speak for — AgentConversationLive keys off :project_name and resolves
      # its own. Assigning defaults here clobbered what it had already loaded.
      {:cont, socket}
    end
  end

  defp project_scoped?(%{"project_id" => _}), do: true
  defp project_scoped?(_), do: false

  defp mount_project_scope(params, socket) do
    socket =
      socket
      |> assign(
        scope: nil,
        project: nil,
        slug: nil,
        scope_error: nil,
        projects: [],
        # S3-backed issue attachments are served by a cloud controller that
        # needs an account scope. The local app has neither yet, so a portable
        # view must not offer a link it cannot follow. Flips to true when the
        # local app gets a real cloud scope.
        full_width: false,
        serves_attachments?: true
      )
      # Resolved here as well as on :handle_params because a LiveView that
      # loads in `mount/3` — mail, mailboxes, project users — runs before the
      # first handle_params and would otherwise see no project at all. The
      # hook still matters: it re-resolves on a live patch to another project.
      |> then(fn socket ->
        case params do
          %{} = params -> elem(put_scope(params, nil, socket), 1)
          _ -> socket
        end
      end)
      |> attach_hook(:portable_scope, :handle_params, &put_scope/3)

    {:cont, socket}
  end

  defp put_scope(%{"project_id" => id}, _uri, socket) do
    with %Scope{} = scope <- socket.assigns.current_scope,
         {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, project} <- Projects.get_project(scope, id) do
      remember(scope, project)

      scope =
        %Scope{scope | active_project: project, active_project_id: project.id}
        |> with_project_environment(project)

      # `:current_scope` carries it too, so cloud views written before the
      # portable contract — mail, mailboxes, project users — keep reading
      # `@current_scope.active_project` unchanged. The URL is what puts a
      # project on a scope; the stored one is only a starting point.
      {:cont,
       assign(socket,
         scope: scope,
         current_scope: scope,
         project: project,
         slug: project.id,
         scope_error: nil
       )}
    else
      nil -> {:cont, fail(socket, "You need to be signed in.")}
      _ -> {:cont, fail(socket, "Project not found.")}
    end
  end

  defp put_scope(_params, _uri, socket), do: {:cont, socket}

  # An HTTP-session scope (`Scope.for_user/1`) carries no environment — every
  # portable LiveView that reads `scope.environment` (Files, this app's own
  # `Environments.glob`/`read_file` callers, `ContentPublishing.sync/1`, ...)
  # got `nil` and quietly treated it as "no files" rather than surfacing an
  # error. `ProvisioningLive.with_project_environment/2` hit this exact gap on
  # one page and patched around it locally; lifted here so every route under
  # `:portable` gets the fix, not just that one.
  #
  # Only the environment is taken, not a whole rebuilt scope —
  # `Scope.for_local_project/2` centers an entire scope on a default local
  # user, and adopting that here would quietly swap out the signed-in user
  # mid-request.
  defp with_project_environment(%{environment: nil} = scope, project) do
    case Scope.for_local_project(project) do
      {:ok, %{environment: env, cwd: cwd}} -> %{scope | environment: env, cwd: cwd}
      _ -> scope
    end
  end

  defp with_project_environment(scope, _project), do: scope

  # Opening a project is what makes it the one you were last in — otherwise the
  # bookmark only ever records what the picker was used for, and bare `/app`
  # sends you somewhere you have not been in weeks. Written only on a change,
  # so navigating around inside one project is not a write per page.
  defp remember(%Scope{active_project_id: same}, %{id: same}), do: :ok

  defp remember(%Scope{} = scope, project) do
    UserPreferences.update_user_preferences(scope, %{active_project_id: project.id})
    :ok
  end

  defp fail(socket, message),
    do: assign(socket, scope: nil, project: nil, scope_error: message)
end
