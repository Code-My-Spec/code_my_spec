defmodule CodeMySpecWeb.WorkingCopyLive.Form do
  @moduledoc """
  Give a working copy a name a person chose.

  Its own route rather than an input on every list row. Two checkouts of one
  project differ in a single directory somewhere deep in a path, so the name is
  the thing that makes the list readable — and an inline box on a read-only list
  is a rename one stray return key away, on the row you happened to be looking
  at rather than the one you meant.

  Blank clears the label, and the copy falls back to rendering its root. That is
  a real thing to want: a name that has gone stale is worse than no name, and
  storing an empty string would show the reader nothing at all.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Harnesses

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Rename")}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      _project ->
        socket.assigns.current_scope
        |> Harnesses.list_harnesses()
        |> Enum.find(&(&1.id == id))
        |> assign_harness(socket)
    end
  end

  defp assign_harness(nil, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "That working copy is not on this project.")
     |> push_navigate(to: ~p"/app/projects/#{socket.assigns.project.id}/working-copies")}
  end

  defp assign_harness(harness, socket) do
    {:noreply,
     socket
     |> assign(:harness, harness)
     |> assign(:form, to_form(%{"label" => harness.label}, as: :working_copy))}
  end

  @impl true
  def handle_event("validate", %{"working_copy" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :working_copy))}
  end

  def handle_event("save", %{"working_copy" => %{"label" => label}}, socket) do
    socket.assigns.current_scope
    |> Harnesses.relabel(socket.assigns.harness, label)
    |> saved(socket)
  end

  defp saved({:ok, _harness}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Working copy renamed.")
     |> push_navigate(
       to:
         ~p"/app/projects/#{socket.assigns.project.id}/working-copies/#{socket.assigns.harness.id}"
     )}
  end

  defp saved({:error, :cross_project}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "That working copy is not on this project.")
     |> push_navigate(to: ~p"/app/projects/#{socket.assigns.project.id}/working-copies")}
  end

  defp saved({:error, _changeset}, socket) do
    {:noreply, put_flash(socket, :error, "That name could not be saved.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      pending_notifications={@pending_notifications}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div data-test="working-copy-form" class="mx-auto w-full max-w-3xl">
        <.header>
          Rename this working copy
          <:subtitle>{@harness.root}</:subtitle>
        </.header>

        <.form
          for={@form}
          id="working-copy-form"
          data-test="rename-form"
          phx-change="validate"
          phx-submit="save"
        >
          <.input
            field={@form[:label]}
            type="text"
            label="Name"
            data-test="label"
            placeholder={@harness.root}
          />

          <p class="mt-1 text-xs opacity-60">
            Leave it blank to go back to showing the path.
          </p>

          <div class="mt-4 flex items-center gap-2">
            <.button phx-disable-with="Saving..." class="btn-primary" data-test="save">Save</.button>
            <.button
              navigate={~p"/app/projects/#{@project.id}/working-copies/#{@harness.id}"}
              class="btn-ghost"
            >
              Cancel
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
