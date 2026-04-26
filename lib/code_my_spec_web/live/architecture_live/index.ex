defmodule CodeMySpecWeb.ArchitectureLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Components
  alias CodeMySpec.Components.DependencyRepository
  alias CodeMySpec.Stories

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <div
          :if={@validation_result}
          class="alert"
          class={validation_result_class(@validation_result)}
        >
          <div class="font-medium">
            {validation_result_title(@validation_result)}
          </div>
          <div class="text-sm">
            {validation_result_message(@validation_result)}
          </div>
        </div>
        <.header>
          Project Architecture
        </.header>

        <div>
          <h3 class="text-lg font-semibold mb-4 flex items-center gap-2">
            <.icon name="hero-document-text" class="size-5" /> Stories & Components
          </h3>

          <ul class="menu bg-base-200 rounded-box w-full">
            <li :for={story <- @architecture_data.unsatisfied}>
              <details>
                <summary class="text-warning font-medium">
                  <.icon name="hero-exclamation-triangle" class="size-4" />
                  {story.title}
                  <span class="text-xs opacity-60">(no component)</span>
                </summary>
                <ul>
                  <li>
                    <div class="flex justify-between items-center">
                      <span class="text-sm text-warning">Needs component assignment</span>
                      <div class="dropdown dropdown-end">
                        <div tabindex="0" role="button" class="btn btn-xs btn-primary">
                          Assign
                        </div>
                        <ul
                          tabindex="0"
                          class="dropdown-content menu bg-base-100 rounded-box z-[1] w-64 p-2 shadow"
                        >
                          <li :for={component <- @available_components}>
                            <a
                              phx-click="assign_component"
                              phx-value-story-id={story.id}
                              phx-value-component-id={component.id}
                            >
                              {component.name} ({component.type})
                            </a>
                          </li>
                        </ul>
                      </div>
                    </div>
                  </li>
                </ul>
              </details>
            </li>

            <li :for={component <- @architecture_data.orphaned}>
              <details>
                <summary class="text-warning font-medium">
                  <.icon name="hero-cube" class="size-4" />
                  {component.name} ({component.type})
                  <span class="text-xs opacity-60">(no stories)</span>
                </summary>
                <ul>
                  <li>
                    <div class="flex justify-between items-center">
                      <span class="text-sm text-warning">Needs story assignment</span>
                      <.live_component
                        module={CodeMySpecWeb.TypeaheadComponent}
                        id={"assign-story-#{component.id}"}
                        items={@architecture_data.unsatisfied}
                        on_select={:assign_story_to_component}
                        extra_params={%{"component_id" => component.id}}
                        placeholder="Assign Story"
                        search_placeholder="Search stories..."
                        button_class="btn btn-xs btn-primary"
                        class="ml-2"
                      >
                        <:item :let={story}>
                          {story.title}
                        </:item>
                      </.live_component>
                    </div>
                  </li>
                </ul>
              </details>
            </li>

            <li :for={%{component: component} <- @architecture_data.satisfied}>
              <details open={MapSet.member?(@expanded_components, component.id)}>
                <summary
                  class="text-success font-medium"
                  phx-click="toggle_component"
                  phx-value-component-id={component.id}
                >
                  <.icon name="hero-cube" class="size-4" />
                  {component.name} ({length(component.stories)} stories)
                </summary>
                <ul>
                  <li>
                    <details open={MapSet.member?(@expanded_stories, component.id)}>
                      <summary phx-click="toggle_stories" phx-value-component-id={component.id}>
                        Stories
                      </summary>
                      <ul>
                        <li
                          :for={story <- component.stories}
                          class="flex flex-row justify-between items-center"
                        >
                          <.link
                            navigate={~p"/app/stories/#{story}/edit"}
                            class="link link-hover text-sm flex-1"
                          >
                            {story.title}
                          </.link>
                          <.live_component
                            module={CodeMySpecWeb.TypeaheadComponent}
                            id={"move-story-#{story.id}"}
                            items={get_other_components(component, @available_components)}
                            on_select={:move_story}
                            extra_params={%{"story_id" => story.id}}
                            placeholder="Move"
                            search_placeholder="Search components..."
                            button_class="btn btn-xs btn-ghost"
                            class="ml-2"
                          >
                            <:item :let={comp}>
                              {comp.name} ({comp.type})
                            </:item>
                          </.live_component>
                        </li>
                      </ul>
                    </details>
                  </li>

                  <li>
                    <details open={MapSet.member?(@expanded_dependencies, component.id)}>
                      <summary
                        phx-click="toggle_dependencies"
                        phx-value-component-id={component.id}
                      >
                        Dependencies
                      </summary>
                      <ul>
                        <li
                          :for={dep <- get_component_dependencies(component)}
                          class="flex flex-row justify-between items-center"
                        >
                          <.link
                            navigate={~p"/app/components/#{dep}/edit"}
                            class="link link-hover text-sm flex-1"
                          >
                            {dep.name} ({dep.type})
                          </.link>
                          <button
                            phx-click="remove_dependency"
                            phx-value-source={component.id}
                            phx-value-target={dep.id}
                            class="btn btn-xs btn-ghost ml-2"
                            title="Remove dependency"
                          >
                            <.icon name="hero-minus-circle" class="size-3" />
                          </button>
                        </li>
                        <li class="mt-2">
                          <.live_component
                            module={CodeMySpecWeb.TypeaheadComponent}
                            id={"add-dependency-#{component.id}"}
                            items={get_available_dependencies(component, @available_components)}
                            on_select={:add_dependency}
                            extra_params={%{"source" => component.id}}
                            placeholder="+ Add"
                            search_placeholder="Search components..."
                            button_class="btn btn-xs btn-primary"
                            class="w-full"
                          >
                            <:item :let={comp}>
                              {comp.name} ({comp.type})
                            </:item>
                          </.live_component>
                        </li>
                      </ul>
                    </details>
                  </li>
                </ul>
              </details>
            </li>

            <li :if={@architecture_data.satisfied == [] and @architecture_data.unsatisfied == []}>
              <div class="text-center py-8">
                <.icon name="hero-cube-transparent" class="size-12 opacity-30 mx-auto mb-2" />
                <p class="text-base-content/60 mb-4">No stories or components</p>
                <div class="flex gap-2 justify-center">
                  <.link navigate={~p"/app/stories/new"} class="btn btn-sm btn-primary">
                    Create Story
                  </.link>
                  <.link navigate={~p"/app/components/new"} class="btn btn-sm btn-outline">
                    Create Component
                  </.link>
                </div>
              </div>
            </li>
          </ul>
        </div>

        <div id="architecture-export" class="hidden">
          {generate_architecture_text(@architecture_data)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Components.subscribe_components(socket.assigns.current_scope)
      Stories.subscribe_stories(socket.assigns.current_scope)
    end

    architecture_data = process_architecture_data(socket.assigns.current_scope)
    available_components = Components.list_components(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Architecture Overview")
     |> assign(:architecture_data, architecture_data)
     |> assign(:available_components, available_components)
     |> assign(:validation_result, nil)
     |> assign(:dependency_order, nil)
     |> assign(:expanded_components, MapSet.new())
     |> assign(:expanded_stories, MapSet.new())
     |> assign(:expanded_dependencies, MapSet.new())}
  end

  @impl true
  def handle_info(
        {_type, %CodeMySpec.Components.Component{}},
        socket
      ) do
    {:noreply, reload_architecture_data(socket)}
  end

  @impl true
  def handle_info(
        {_type, %CodeMySpec.Stories.Story{}},
        socket
      ) do
    {:noreply, reload_architecture_data(socket)}
  end

  @impl true
  def handle_info({:add_dependency, params}, socket) do
    handle_event("add_dependency", params, socket)
  end

  @impl true
  def handle_info({:move_story, params}, socket) do
    handle_event("move_story", params, socket)
  end

  @impl true
  def handle_info({:assign_story_to_component, params}, socket) do
    handle_event("assign_story_to_component", params, socket)
  end

  @impl true
  def handle_event(
        "assign_component",
        %{"story-id" => story_id, "component-id" => component_id},
        socket
      ) do
    story = Stories.get_story!(socket.assigns.current_scope, story_id)

    case Stories.set_story_component(
           socket.assigns.current_scope,
           story,
           String.to_integer(component_id)
         ) do
      {:ok, _updated_story} ->
        {:noreply, reload_architecture_data(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to assign component")}
    end
  end

  @impl true
  def handle_event("unassign_component", %{"story-id" => story_id}, socket) do
    story = Stories.get_story!(socket.assigns.current_scope, story_id)

    case Stories.clear_story_component(socket.assigns.current_scope, story) do
      {:ok, _updated_story} ->
        {:noreply, reload_architecture_data(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to unassign component")}
    end
  end

  @impl true
  def handle_event("move_story", %{"id" => component_id, "story_id" => story_id}, socket) do
    story = Stories.get_story!(socket.assigns.current_scope, story_id)

    case Stories.set_story_component(
           socket.assigns.current_scope,
           story,
           ensure_integer(component_id)
         ) do
      {:ok, _updated_story} ->
        {:noreply, reload_architecture_data(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to move story")}
    end
  end

  @impl true
  def handle_event(
        "assign_story_to_component",
        %{"id" => story_id, "component_id" => component_id},
        socket
      ) do
    story = Stories.get_story!(socket.assigns.current_scope, story_id)

    case Stories.set_story_component(
           socket.assigns.current_scope,
           story,
           ensure_integer(component_id)
         ) do
      {:ok, _updated_story} ->
        {:noreply, reload_architecture_data(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to assign story to component")}
    end
  end

  @impl true
  def handle_event("add_dependency", %{"id" => target_id, "source" => source_id}, socket) do
    case DependencyRepository.create_dependency(socket.assigns.current_scope, %{
           source_component_id: ensure_integer(source_id),
           target_component_id: ensure_integer(target_id)
         }) do
      {:ok, _dependency} ->
        {:noreply, reload_architecture_data(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create dependency")}
    end
  end

  @impl true
  def handle_event("remove_dependency", %{"source" => source_id, "target" => target_id}, socket) do
    # Find and delete the dependency
    dependencies = DependencyRepository.list_dependencies(socket.assigns.current_scope)

    case Enum.find(dependencies, fn dep ->
           dep.source_component_id == ensure_integer(source_id) and
             dep.target_component_id == ensure_integer(target_id)
         end) do
      nil ->
        {:noreply, put_flash(socket, :error, "Dependency not found")}

      dependency ->
        case DependencyRepository.delete_dependency(socket.assigns.current_scope, dependency) do
          {:ok, _dependency} ->
            {:noreply, reload_architecture_data(socket)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to remove dependency")}
        end
    end
  end

  @impl true
  def handle_event("toggle_component", %{"component-id" => component_id}, socket) do
    component_id = ensure_integer(component_id)

    expanded_components =
      if MapSet.member?(socket.assigns.expanded_components, component_id) do
        MapSet.delete(socket.assigns.expanded_components, component_id)
      else
        MapSet.put(socket.assigns.expanded_components, component_id)
      end

    {:noreply, assign(socket, :expanded_components, expanded_components)}
  end

  @impl true
  def handle_event("toggle_stories", %{"component-id" => component_id}, socket) do
    component_id = ensure_integer(component_id)

    expanded_stories =
      if MapSet.member?(socket.assigns.expanded_stories, component_id) do
        MapSet.delete(socket.assigns.expanded_stories, component_id)
      else
        MapSet.put(socket.assigns.expanded_stories, component_id)
      end

    {:noreply, assign(socket, :expanded_stories, expanded_stories)}
  end

  @impl true
  def handle_event("toggle_dependencies", %{"component-id" => component_id}, socket) do
    component_id = ensure_integer(component_id)

    expanded_dependencies =
      if MapSet.member?(socket.assigns.expanded_dependencies, component_id) do
        MapSet.delete(socket.assigns.expanded_dependencies, component_id)
      else
        MapSet.put(socket.assigns.expanded_dependencies, component_id)
      end

    {:noreply, assign(socket, :expanded_dependencies, expanded_dependencies)}
  end

  defp reload_architecture_data(socket) do
    architecture_data = process_architecture_data(socket.assigns.current_scope)
    available_components = Components.list_components(socket.assigns.current_scope)

    socket
    |> assign(:architecture_data, architecture_data)
    |> assign(:available_components, available_components)

    # Preserve existing expanded state - no changes needed here since we're not reassigning the expanded sets
  end

  defp process_architecture_data(scope) do
    architecture_components = Components.show_architecture(scope)
    unsatisfied_stories = Stories.list_unsatisfied_stories(scope)
    orphaned_components = Components.list_orphaned_contexts(scope)

    %{
      satisfied: architecture_components,
      unsatisfied: unsatisfied_stories,
      orphaned: orphaned_components
    }
  end

  defp get_component_dependencies(component) do
    case component.outgoing_dependencies do
      %Ecto.Association.NotLoaded{} -> []
      deps when is_list(deps) -> Enum.map(deps, & &1.target_component)
      _ -> []
    end
  end

  defp get_available_dependencies(current_component, all_components) do
    existing_dep_ids =
      current_component
      |> get_component_dependencies()
      |> Enum.map(& &1.id)
      |> MapSet.new()

    all_components
    |> Enum.reject(fn comp ->
      comp.id == current_component.id or MapSet.member?(existing_dep_ids, comp.id)
    end)
  end

  defp get_other_components(current_component, all_components) do
    Enum.reject(all_components, fn comp -> comp.id == current_component.id end)
  end

  defp ensure_integer(value) when is_integer(value), do: value
  defp ensure_integer(value) when is_binary(value), do: String.to_integer(value)

  defp validation_result_class(:ok), do: "alert-success"
  defp validation_result_class({:error, _}), do: "alert-error"

  defp validation_result_title(:ok), do: "Valid Dependencies"
  defp validation_result_title({:error, _}), do: "Circular Dependencies Found"

  defp validation_result_message(:ok), do: "No circular dependencies detected."

  defp validation_result_message({:error, cycles}) do
    cycle_count = length(cycles)

    "Found #{cycle_count} circular #{if cycle_count == 1, do: "dependency", else: "dependencies"}."
  end

  defp generate_architecture_text(architecture_data) do
    unsatisfied_section(architecture_data.unsatisfied) <>
      satisfied_section(architecture_data.satisfied)
  end

  defp unsatisfied_section([]), do: ""

  defp unsatisfied_section(stories) do
    "UNSATISFIED STORIES:\n" <>
      Enum.map_join(stories, "\n", fn story -> "- #{story.title}" end) <>
      "\n\n"
  end

  defp satisfied_section([]), do: ""

  defp satisfied_section(component_list) do
    "SATISFIED COMPONENTS:\n" <>
      Enum.map_join(component_list, "\n", &format_satisfied_component/1)
  end

  defp format_satisfied_component(%{component: component}) do
    stories_text = Enum.map_join(component.stories, ", ", & &1.title)
    deps_text = format_component_deps(get_component_dependencies(component))

    "- #{component.name} (#{component.type}) serves: #{stories_text}" <> deps_text
  end

  defp format_component_deps([]), do: ""

  defp format_component_deps(deps) do
    "\n  Dependencies: " <>
      Enum.map_join(deps, ", ", fn dep -> "#{dep.name} (#{dep.type})" end)
  end
end
