defmodule CodeMySpecLocalWeb.PersonasLive.FormComponent do
  @moduledoc """
  Create and edit personas. Validates via the Persona changeset; saves through
  the Personas context. Notifies the parent on save with `:persona_saved`.
  """
  use CodeMySpecLocalWeb, :live_component

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Persona

  @persona_types [:proto, :qualitative, :statistical]

  @impl true
  def update(%{persona: persona, action: action} = assigns, socket) do
    changeset = Persona.changeset(persona, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:action, action)
     |> assign(:persona_types, @persona_types)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"persona" => params}, socket) do
    changeset =
      socket.assigns.persona
      |> Persona.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"persona" => params}, socket) do
    save_persona(socket, socket.assigns.action, params)
  end

  defp save_persona(socket, :new, params) do
    case Personas.create_persona(socket.assigns.scope, params) do
      {:ok, persona} ->
        notify_parent(persona)

        {:noreply,
         socket
         |> put_flash(:info, "Persona created")
         |> push_patch(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create persona: #{inspect(reason)}")}
    end
  end

  defp save_persona(socket, :edit, params) do
    case Personas.update_persona(socket.assigns.scope, socket.assigns.persona, params) do
      {:ok, persona} ->
        notify_parent(persona)

        {:noreply,
         socket
         |> put_flash(:info, "Persona updated")
         |> push_patch(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not update persona: #{inspect(reason)}")}
    end
  end

  defp notify_parent(persona), do: send(self(), {:persona_saved, persona})

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "persona"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {if @action == :new, do: "New Persona", else: "Edit Persona"}
        <:subtitle>
          Identity + metadata only — research artifacts live in the local repo at
          <code>.code_my_spec/personas/&lt;slug&gt;/</code>.
        </:subtitle>
      </.header>

      <.form
        for={@form}
        id={"persona-form-#{@id}"}
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
      >
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input
          field={@form[:slug]}
          type="text"
          label="Slug"
          required
          placeholder="lowercase-with-hyphens"
        />
        <p class="text-xs text-base-content/60 -mt-2">
          URL-safe identifier. Lowercase alphanumeric with hyphens or underscores.
        </p>

        <.input field={@form[:headline]} type="text" label="Headline" />

        <.input
          field={@form[:persona_type]}
          type="select"
          label="Persona Type"
          options={Enum.map(@persona_types, &{Phoenix.Naming.humanize(&1), &1})}
        />

        <div class="flex justify-end gap-2 pt-4">
          <.button type="button" phx-click={JS.patch(@return_to)} class="btn btn-ghost">
            Cancel
          </.button>
          <.button type="submit" phx-disable-with="Saving..." class="btn btn-primary">
            Save
          </.button>
        </div>
      </.form>
    </div>
    """
  end
end
