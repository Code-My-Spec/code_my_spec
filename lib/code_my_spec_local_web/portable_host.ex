defmodule CodeMySpecLocalWeb.PortableHost do
  @moduledoc """
  Supplies the local app's half of what a portable LiveView needs.

  Portable views live in `CodeMySpecWeb` and are mounted by both routers. They
  contain nothing app-specific: no layout module, no scope building, no project
  lookup. Everything that differs between the two apps arrives as assigns, put
  there by this hook and by the `layout:` on the router's `live_session`.

  ## The contract

  Every portable view can rely on these assigns existing:

    * `:scope`   — a `CodeMySpec.Users.Scope` for the project in the URL
    * `:project` — the project itself
    * `:slug`    — its URL segment (a name slug here, a UUID in the cloud)
    * `:error`   — nil, or a message fit to render in an alert

  Plus whatever `CodeMySpecLocalWeb.Layouts.live/1` reads. The cloud host
  (`CodeMySpecWeb.PortableHost`) implements the same contract against the
  cloud's chrome and its account-scoped project lookup.

  Resolution is attached to `:handle_params` rather than done in `mount/3`
  because the project can change on a live patch.
  """

  use CodeMySpecLocalWeb, :html

  import Phoenix.LiveView, only: [attach_hook: 4]

  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  def on_mount(:default, params, _session, socket) do
    if match?(%{"project_id" => _}, params) do
      mount_project_scope(params, socket)
    else
      # Routes in this session that don't name a project aren't ours to speak
      # for — see CodeMySpecWeb.PortableHost.
      {:cont, socket}
    end
  end

  defp mount_project_scope(params, socket) do
    socket =
      socket
      |> assign(
        projects: Projects.list_local_projects(),
        scope: nil,
        project: nil,
        slug: nil,
        scope_error: nil,
        # The cloud layout reads these; defaulting them here keeps the portable
        # views free of `assigns[:maybe]` lookups.
        current_scope: nil,
        current_path: "/",
        full_width: false,
        # see CodeMySpecWeb.PortableHost — no account scope here yet
        serves_attachments?: false
      )
      # Resolved at mount as well as on :handle_params — a LiveView that loads
      # in `mount/3` runs before the first handle_params and would otherwise
      # see no project. The hook still re-resolves on a live patch.
      |> then(fn socket ->
        case params do
          %{} = params -> elem(put_scope(params, nil, socket), 1)
          _ -> socket
        end
      end)
      |> attach_hook(:portable_scope, :handle_params, &put_scope/3)

    {:cont, socket}
  end

  # Both apps address a project by id. `get_project_by_id/1` rather than the
  # scoped `get_project/2` because there is no account to scope by here — one
  # developer, one machine. Authentication is now the only thing left that
  # differs between this host and the cloud's.
  defp put_scope(%{"project_id" => id}, _uri, socket) do
    with %Projects.Project{} = project <- Projects.get_project_by_id(id),
         {:ok, scope} <- Scope.for_local_project(project) do
      # `:current_scope` gets the same scope, exactly as the cloud host does.
      # Portable views are written against the cloud's assign names, and some
      # query through `current_scope` rather than `scope` — IssuesLive does.
      # Leaving it at its nil default meant those ran their queries with no
      # scope at all in this app, on pages that still rendered.
      {:cont,
       assign(socket,
         scope: scope,
         current_scope: scope,
         project: project,
         slug: project.id,
         scope_error: nil
       )}
    else
      nil -> {:cont, fail(socket, "Project not found.")}
      {:error, reason} -> {:cont, fail(socket, "#{reason}")}
    end
  end

  # A route in this live_session that doesn't name a project isn't ours to
  # speak for — AgentConversationLive keys off :project_name and resolves its
  # own. Assigning nils here clobbered the project it had already loaded.
  defp put_scope(_params, _uri, socket), do: {:cont, socket}

  defp fail(socket, message),
    do: assign(socket, scope: nil, current_scope: nil, project: nil, scope_error: message)
end
