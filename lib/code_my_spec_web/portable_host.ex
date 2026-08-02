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
  alias CodeMySpec.Users.Scope

  def on_mount(:default, params, _session, socket) do
    socket =
      socket
      |> assign(scope: nil, project: nil, slug: nil, scope_error: nil, projects: [])
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
      scope = %Scope{scope | active_project: project, active_project_id: project.id}

      # `:current_scope` carries it too, so cloud views written before the
      # portable contract — mail, mailboxes, project users — keep reading
      # `@current_scope.active_project` unchanged. This is the only place a
      # project reaches a scope now that nothing is persisted.
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

  defp put_scope(_params, _uri, socket), do: {:cont, fail(socket, "No project in the URL.")}

  defp fail(socket, message),
    do: assign(socket, scope: nil, project: nil, scope_error: message)
end
