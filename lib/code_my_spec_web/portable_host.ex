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

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(scope: nil, project: nil, slug: nil, error: nil, projects: [])
      |> attach_hook(:portable_scope, :handle_params, &put_scope/3)

    {:cont, socket}
  end

  defp put_scope(%{"project_id" => id}, _uri, socket) do
    with %Scope{} = scope <- socket.assigns.current_scope,
         {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, project} <- Projects.get_project(scope, id) do
      scope = %Scope{scope | active_project: project, active_project_id: project.id}
      {:cont, assign(socket, scope: scope, project: project, slug: project.id, error: nil)}
    else
      nil -> {:cont, fail(socket, "You need to be signed in.")}
      _ -> {:cont, fail(socket, "Project not found.")}
    end
  end

  defp put_scope(_params, _uri, socket), do: {:cont, fail(socket, "No project in the URL.")}

  defp fail(socket, message), do: assign(socket, scope: nil, project: nil, error: message)
end
