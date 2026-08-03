defmodule CodeMySpecWeb.Live.CurrentPathHook do
  @moduledoc """
  Assigns what the app chrome needs on every authenticated LiveView: where the
  user is, and where they could go instead.

  The project list lives here rather than in `PortableHost` because the sidebar
  needs it precisely when the host has nothing to say — on `/app`, on
  `/app/accounts`, on any page with no project in its path. That is exactly
  when the sidebar offers a picker, and a picker with nothing to pick from is
  a blank box.

  The list is built in the `handle_params` hook rather than in `on_mount`
  because this hook is declared first in every `live_session`, which means it
  runs before `UserAuth.require_authenticated` has put `current_scope` on the
  socket. `handle_params` runs after every `on_mount` has finished, so the
  scope is there. `assign_new/3` keeps it to one query — later patches skip it,
  and a view that builds its own list keeps that.
  """
  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias CodeMySpec.Projects

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :current_path, :handle_params, &assign_chrome/3)}
  end

  defp assign_chrome(_params, uri, socket) do
    socket =
      socket
      |> assign(:current_path, URI.parse(uri).path)
      |> assign_new(:projects, fn -> list_projects(socket.assigns[:current_scope]) end)

    {:cont, socket}
  end

  # A scope with no account cannot own projects yet — that user is still in
  # onboarding, where the sidebar is hidden anyway.
  defp list_projects(%{active_account_id: id} = scope) when not is_nil(id),
    do: Projects.list_projects(scope)

  defp list_projects(_scope), do: []
end
