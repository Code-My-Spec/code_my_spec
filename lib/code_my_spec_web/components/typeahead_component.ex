defmodule CodeMySpecWeb.TypeaheadComponent do
  @moduledoc false
  use CodeMySpecWeb, :live_component

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:search_value, fn -> "" end)
      |> assign_new(:filtered_items, fn -> [] end)
      |> assign_new(:show_dropdown, fn -> false end)
      |> assign_new(:show_input, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"value" => search_value}, socket) do
    filtered_items = filter_items(socket.assigns.items, search_value)

    socket =
      socket
      |> assign(:search_value, search_value)
      |> assign(:filtered_items, filtered_items)
      |> assign(:show_dropdown, String.length(search_value) > 0)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_input", _, socket) do
    show_input = !socket.assigns.show_input

    socket =
      socket
      |> assign(:show_input, show_input)
      |> assign(:search_value, if(show_input, do: "", else: ""))
      |> assign(:show_dropdown, false)
      |> assign(:filtered_items, [])

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_item", %{"id" => id}, socket) do
    send(
      self(),
      {socket.assigns.on_select, %{"id" => id} |> Map.merge(socket.assigns.extra_params || %{})}
    )

    socket =
      socket
      |> assign(:search_value, "")
      |> assign(:show_dropdown, false)
      |> assign(:filtered_items, [])
      |> assign(:show_input, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("focus", _, socket) do
    filtered_items = filter_items(socket.assigns.items, socket.assigns.search_value)

    {:noreply, assign(socket, show_dropdown: true, filtered_items: filtered_items)}
  end

  @impl true
  def handle_event("blur", _, socket) do
    {:noreply, assign(socket, show_dropdown: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["relative", @class || ""]} phx-click-away={JS.push("blur", target: @myself)}>
      <!-- Button state -->
      <button
        :if={!@show_input}
        phx-click={JS.push("toggle_input", target: @myself)}
        class={@button_class || "btn btn-xs btn-primary"}
      >
        {@placeholder || "Add..."}
      </button>
      
    <!-- Input state -->
      <div :if={@show_input} class="flex gap-1 items-center">
        <input
          type="text"
          placeholder={@search_placeholder || "Search..."}
          class="input input-bordered input-xs flex-1"
          value={@search_value}
          phx-keyup={JS.push("search", target: @myself)}
          phx-focus={JS.push("focus", target: @myself)}
          phx-value-value={@search_value}
        />
        <button phx-click={JS.push("toggle_input", target: @myself)} class="btn btn-xs btn-ghost">
          ×
        </button>
      </div>
      
    <!-- Dropdown -->
      <div
        :if={@show_input and @show_dropdown and length(@filtered_items) > 0}
        class="absolute top-full left-0 right-0 bg-base-100 border border-base-300 rounded-box shadow-lg z-50 max-h-60 overflow-y-auto mt-1"
      >
        <ul class="menu p-2">
          <li :for={item <- @filtered_items}>
            <a
              phx-click={JS.push("select_item", value: %{id: Map.get(item, :id)}, target: @myself)}
              class="block p-2 hover:bg-base-200 rounded cursor-pointer"
            >
              {render_slot(@item, item)}
            </a>
          </li>
        </ul>
      </div>
      
    <!-- No results -->
      <div
        :if={@show_input and @show_dropdown and @search_value != "" and length(@filtered_items) == 0}
        class="absolute top-full left-0 right-0 bg-base-100 border border-base-300 rounded-box shadow-lg z-50 mt-1"
      >
        <div class="p-4 text-center text-base-content/60">
          No matches found
        </div>
      </div>
    </div>
    """
  end

  defp filter_items(items, search_value) when search_value == "" do
    Enum.take(items, 5)
  end

  defp filter_items(items, search_value) do
    search_lower = String.downcase(search_value)

    Enum.filter(items, fn item ->
      name = Map.get(item, :name) || Map.get(item, :title) || ""
      type = Map.get(item, :type) || ""

      # Convert type to string safely
      type_string =
        case type do
          atom when is_atom(atom) -> Atom.to_string(atom)
          string when is_binary(string) -> string
          _ -> ""
        end

      String.contains?(String.downcase(name), search_lower) or
        String.contains?(String.downcase(type_string), search_lower)
    end)
  end
end
