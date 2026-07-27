defmodule CodeMySpecLocalWeb.EpicsLive.FormComponent do
  @moduledoc """
  Form for creating and editing an epic — name and description. The slug is
  derived from the name rather than entered.
  """
  use CodeMySpecLocalWeb, :live_component

  alias CodeMySpec.Epics

  @impl true
  def update(%{epic: epic} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn -> to_form(Epics.change_epic(epic)) end)}
  end

  @impl true
  def handle_event("validate", %{"epic" => attrs}, socket) do
    changeset =
      socket.assigns.epic
      |> Epics.change_epic(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"epic" => attrs}, socket) do
    save_epic(socket, socket.assigns.action, attrs)
  end

  defp save_epic(socket, :new, attrs) do
    case Epics.create_epic(socket.assigns.scope, attrs) do
      {:ok, epic} ->
        send(self(), {:epic_saved, epic})

        {:noreply,
         socket
         |> put_flash(:info, "Epic created")
         |> push_patch(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create epic: #{inspect(reason)}")}
    end
  end

  defp save_epic(socket, :edit, attrs) do
    case Epics.update_epic(socket.assigns.scope, socket.assigns.epic, attrs) do
      {:ok, epic} ->
        send(self(), {:epic_saved, epic})

        {:noreply,
         socket
         |> put_flash(:info, "Epic updated")
         |> push_patch(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not update epic: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {if @action == :new, do: "New epic", else: "Edit epic"}
        <:subtitle>
          Grouping stories does not release them for development.
        </:subtitle>
      </.header>

      <.form
        for={@form}
        id="epic-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        data-test="epic-form"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:description]} type="textarea" label="Description" />

        <div class="mt-4 flex justify-end gap-2">
          <.button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
            Save epic
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
