defmodule CodeMySpecWeb.ComponentLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Listing Components
        <:actions>
          <.button navigate={~p"/app/components/new"}>
            <.icon name="hero-plus" /> New Component
          </.button>
        </:actions>
      </.header>

      <div class="space-y-8">
        <div :for={{id, component} <- @streams.components} id={id} class="card bg-base-100 shadow-md">
          <div class="card-body">
            <h2
              class="card-title text-2xl mb-4 cursor-pointer hover:text-primary"
              phx-click={JS.navigate(~p"/app/components/#{component}/edit")}
            >
              {component.name}
            </h2>

            <div class="mb-4">
              <div class="flex items-center gap-4 mb-2">
                <.badge color="primary">{component.type}</.badge>
                <span class="text-base-content/60 font-mono text-sm">{component.module_name}</span>
              </div>

              <div class="flex items-center gap-6 text-sm text-base-content/60">
                <span>Dependencies: {safe_length(component.dependencies)}</span>
                <span>Stories: {safe_length(component.stories)}</span>
              </div>
            </div>

            <p :if={component.description} class="text-base-content/80 mb-4 leading-relaxed">
              {component.description}
            </p>

            <div :if={loaded_and_present?(component.stories)} class="mb-4">
              <h3 class="font-semibold mb-2">Stories:</h3>
              <div class="flex flex-wrap gap-2">
                <.link
                  :for={story <- component.stories}
                  navigate={~p"/app/stories/#{story}"}
                  class="badge badge-outline badge-info hover:badge-info"
                >
                  {story.title}
                </.link>
              </div>
            </div>

            <div :if={loaded_and_present?(component.dependencies)} class="mb-4">
              <h3 class="font-semibold mb-2">Dependencies:</h3>
              <div class="flex flex-wrap gap-2">
                <.link
                  :for={dep <- component.dependencies}
                  navigate={~p"/app/components/#{dep}/edit"}
                  class="badge badge-outline badge-secondary hover:badge-secondary"
                >
                  {dep.name}
                </.link>
              </div>
            </div>

            <div class="flex items-center justify-end">
              <div class="card-actions">
                <.link navigate={~p"/app/components/#{component}/edit"} class="btn btn-sm btn-outline">
                  Edit
                </.link>
                <.link
                  phx-click={JS.push("delete", value: %{id: component.id}) |> hide("##{id}")}
                  data-confirm="Are you sure?"
                  class="btn btn-sm btn-error btn-outline"
                >
                  Delete
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Components.subscribe_components(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Components")
     |> stream(
       :components,
       Components.list_components_with_dependencies(socket.assigns.current_scope)
       |> Enum.sort_by(&component_sort_key/1)
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    component = Components.get_component!(socket.assigns.current_scope, id)
    {:ok, _} = Components.delete_component(socket.assigns.current_scope, component)

    {:noreply, stream_delete(socket, :components, component)}
  end

  @impl true
  def handle_info({type, %Component{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(
       socket,
       :components,
       Components.list_components_with_dependencies(socket.assigns.current_scope)
       |> Enum.sort_by(&component_sort_key/1),
       reset: true
     )}
  end

  defp component_sort_key(%{name: name}), do: name

  defp safe_length(%Ecto.Association.NotLoaded{}), do: 0
  defp safe_length(nil), do: 0
  defp safe_length(list) when is_list(list), do: length(list)

  defp loaded_and_present?(%Ecto.Association.NotLoaded{}), do: false
  defp loaded_and_present?(nil), do: false
  defp loaded_and_present?([]), do: false
  defp loaded_and_present?(list) when is_list(list), do: true
end
