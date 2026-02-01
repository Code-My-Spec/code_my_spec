defmodule CodeMySpecWeb.ComponentLive.Form do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component
  alias CodeMySpecWeb.ComponentLive.SimilarComponentsSelector

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage component records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="component-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:type]} type="text" label="Type" />
        <.input field={@form[:module_name]} type="text" label="Module Name" />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <.input
          field={@form[:parent_component_id]}
          type="select"
          label="Parent Component"
          prompt="Choose a parent component (optional)"
          options={Enum.map(@contexts, &{&1.name, &1.id})}
        />

        <.live_component
          module={SimilarComponentsSelector}
          id="similar-components-selector"
          current_scope={@current_scope}
          component={@component}
          selected_similar_ids={@selected_similar_ids}
        />

        <footer>
          <.button phx-disable-with="Saving...">Save Component</.button>
          <.button navigate={return_path(@current_scope, @return_to, @component)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    scope = socket.assigns.current_scope
    component = Components.get_component!(scope, id)
    contexts = Components.list_contexts(scope)

    # Load similar components for editing
    similar_components = Components.list_similar_components(scope, component)
    similar_component_ids = Enum.map(similar_components, & &1.id)

    socket
    |> assign(:page_title, "Edit Component")
    |> assign(:component, component)
    |> assign(:contexts, contexts)
    |> assign(:selected_similar_ids, similar_component_ids)
    |> assign(
      :form,
      to_form(Components.change_component(socket.assigns.current_scope, component))
    )
  end

  defp apply_action(socket, :new, _params) do
    component = %Component{
      project_id: socket.assigns.current_scope.active_project.id,
      account_id: socket.assigns.current_scope.active_account.id
    }

    contexts = Components.list_contexts(socket.assigns.current_scope)

    socket
    |> assign(:page_title, "New Component")
    |> assign(:component, component)
    |> assign(:contexts, contexts)
    |> assign(:selected_similar_ids, [])
    |> assign(
      :form,
      to_form(Components.change_component(socket.assigns.current_scope, component))
    )
  end

  @impl true
  def handle_event("validate", %{"component" => component_params}, socket) do
    changeset =
      Components.change_component(
        socket.assigns.current_scope,
        socket.assigns.component,
        component_params
      )

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"component" => component_params}, socket) do
    save_component(socket, socket.assigns.live_action, component_params)
  end

  @impl true
  def handle_info({:similar_components_updated, similar_ids}, socket) do
    {:noreply, assign(socket, :selected_similar_ids, similar_ids)}
  end

  defp save_component(socket, :edit, component_params) do
    case Components.update_component(
           socket.assigns.current_scope,
           socket.assigns.component,
           component_params
         ) do
      {:ok, component} ->
        # Update similar components association
        update_similar_components(
          socket.assigns.current_scope,
          component,
          socket.assigns.selected_similar_ids
        )

        {:noreply,
         socket
         |> put_flash(:info, "Component updated successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, component)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_component(socket, :new, component_params) do
    case Components.create_component(socket.assigns.current_scope, component_params) do
      {:ok, component} ->
        # Set similar components association
        update_similar_components(
          socket.assigns.current_scope,
          component,
          socket.assigns.selected_similar_ids
        )

        {:noreply,
         socket
         |> put_flash(:info, "Component created successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, component)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path(_scope, "index", _component), do: ~p"/app/components"
  defp return_path(_scope, "show", _component), do: ~p"/app/components"

  defp update_similar_components(scope, component, similar_ids) when is_list(similar_ids) do
    # Sync the similar_components join table to match the selected IDs
    # This handles adds, removes, and clearing all similar components
    case Components.sync_similar_components(scope, component, similar_ids) do
      {:ok, _component} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("Failed to sync similar components: #{inspect(reason)}")
        :error
    end
  end
end
