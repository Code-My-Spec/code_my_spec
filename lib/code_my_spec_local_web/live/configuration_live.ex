defmodule CodeMySpecLocalWeb.ConfigurationLive do
  @moduledoc """
  Local quality gate configuration.

  Engineer toggles what's required and what blocks. Changes persist to
  ProjectConfiguration and take effect immediately — the requirements graph
  and the stop hook pipeline both read from this record.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Configurations
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @analyzer_modes [:off, :block_all, :block_changed, :dont_block]
  @compile_modes [:block, :dont_block]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, error: nil, flash_message: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project, scope} <- load_project_and_scope(name) do
      configuration = Configurations.get_or_create(scope)

      {:noreply,
       assign(socket,
         project: project,
         scope: scope,
         configuration: configuration,
         analyzer_modes: @analyzer_modes,
         compile_modes: @compile_modes,
         page_title: "#{project.name} — Configuration",
         error: nil
       )}
    else
      {:error, msg} -> {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  @impl true
  def handle_event("save", %{"configuration" => attrs}, socket) do
    # Checkboxes not present in params = unchecked.
    attrs = normalize_checkbox_attrs(attrs)

    case Configurations.update(socket.assigns.scope, attrs) do
      {:ok, configuration} ->
        {:noreply,
         socket
         |> assign(configuration: configuration, flash_message: "Configuration saved")}

      {:error, _changeset} ->
        {:noreply, assign(socket, flash_message: "Failed to save configuration")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} style="color: #f87171;">
      <h1>Error</h1>
      <p>{@error}</p>
    </div>

    <div :if={!@error} class="prose prose-invert">
      <h1>{@project.name} — Configuration</h1>
      <p>Local quality gate settings. Never synced to the server.</p>

      <div :if={@flash_message} style="color: #4ade80;">{@flash_message}</div>

      <form id="configuration-form" data-test="configuration-form" phx-submit="save">
        <section>
          <h2>Requirement Toggles</h2>
          <p>What's required for a component to be considered done.</p>

          <label>
            <input
              type="hidden"
              name="configuration[require_specs]"
              value="false"
            />
            <input
              type="checkbox"
              name="configuration[require_specs]"
              value="true"
              checked={@configuration.require_specs}
              data-test="require-specs"
            />
            Require Specs
          </label>

          <label>
            <input
              type="hidden"
              name="configuration[require_reviews]"
              value="false"
            />
            <input
              type="checkbox"
              name="configuration[require_reviews]"
              value="true"
              checked={@configuration.require_reviews}
              data-test="require-reviews"
            />
            Require Reviews
          </label>

          <label>
            <input
              type="hidden"
              name="configuration[require_unit_tests]"
              value="false"
            />
            <input
              type="checkbox"
              name="configuration[require_unit_tests]"
              value="true"
              checked={@configuration.require_unit_tests}
              data-test="require-unit-tests"
            />
            Require Unit Tests
          </label>
        </section>

        <section>
          <h2>Analyzer Settings</h2>
          <p>What runs at stop time and whether it blocks.</p>

          <label>
            Compile Warnings
            <select name="configuration[compile_warnings]" data-test="compile-warnings">
              <option
                :for={mode <- @compile_modes}
                value={mode}
                selected={@configuration.compile_warnings == mode}
              >
                {format_mode(mode)}
              </option>
            </select>
          </label>

          <label>
            Credo
            <select name="configuration[credo]" data-test="credo">
              <option
                :for={mode <- @analyzer_modes}
                value={mode}
                selected={@configuration.credo == mode}
              >
                {format_mode(mode)}
              </option>
            </select>
          </label>

          <label>
            ExUnit
            <select name="configuration[exunit]" data-test="exunit">
              <option
                :for={mode <- @analyzer_modes}
                value={mode}
                selected={@configuration.exunit == mode}
              >
                {format_mode(mode)}
              </option>
            </select>
          </label>

          <label>
            Spex
            <select name="configuration[spex]" data-test="spex">
              <option
                :for={mode <- @analyzer_modes}
                value={mode}
                selected={@configuration.spex == mode}
              >
                {format_mode(mode)}
              </option>
            </select>
          </label>
        </section>

        <footer>
          <button type="submit" data-test="save-configuration">Save Configuration</button>
        </footer>
      </form>
    </div>
    """
  end

  defp normalize_checkbox_attrs(attrs) do
    attrs
    |> Map.update("require_specs", false, &parse_bool/1)
    |> Map.update("require_reviews", false, &parse_bool/1)
    |> Map.update("require_unit_tests", false, &parse_bool/1)
  end

  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false

  defp format_mode(:off), do: "Off"
  defp format_mode(:block_all), do: "Block All"
  defp format_mode(:block_changed), do: "Block Changed"
  defp format_mode(:dont_block), do: "Don't Block"
  defp format_mode(:block), do: "Block"

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end
end
