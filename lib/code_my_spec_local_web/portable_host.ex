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

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(
        projects: Projects.list_local_projects(),
        scope: nil,
        project: nil,
        slug: nil,
        error: nil,
        # The cloud layout reads these; defaulting them here keeps the portable
        # views free of `assigns[:maybe]` lookups.
        current_scope: nil,
        current_path: "/",
        pending_notifications: 0
      )
      |> attach_hook(:portable_scope, :handle_params, &put_scope/3)

    {:cont, socket}
  end

  # The cloud's project segment carries a UUID; locally it carries the same
  # name slug the rest of the local app routes on, so the shared `~p` literals
  # produce URLs that read naturally in both.
  defp put_scope(%{"project_id" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:cont,
       assign(socket, scope: scope, project: project, slug: slug(project), error: nil)}
    else
      {:error, :not_found} -> {:cont, fail(socket, "Project not found.")}
      {:error, reason} -> {:cont, fail(socket, "#{reason}")}
    end
  end

  defp put_scope(_params, _uri, socket), do: {:cont, fail(socket, "No project in the URL.")}

  defp fail(socket, message), do: assign(socket, scope: nil, project: nil, error: message)

  defp slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
