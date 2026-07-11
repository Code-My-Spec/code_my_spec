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
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
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

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  @impl true
  def handle_event("save", %{"configuration" => attrs}, socket) do
    attrs = normalize_checkbox_attrs(attrs)

    case Configurations.update(socket.assigns.scope, attrs) do
      {:ok, configuration} ->
        {:noreply,
         socket
         |> assign(configuration: configuration)
         |> put_flash(:info, "Configuration saved")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save configuration")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:configuration}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project}>
        <div class="mb-6">
          <h1 class="text-3xl font-bold">Configuration</h1>
          <p class="text-base-content/60 mt-1">
            Local quality gate settings. Never synced to the server.
          </p>
        </div>

        <form id="configuration-form" data-test="configuration-form" phx-submit="save" class="space-y-6">
          <section class="card bg-base-200 border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-lg">Requirement Toggles</h2>
              <p class="text-sm opacity-70">What's required for a component to be considered done.</p>

              <div class="divider my-1"></div>

              <.toggle_field
                name="require_specs"
                label="Require Specs"
                checked={@configuration.require_specs}
              />
              <.toggle_field
                name="require_reviews"
                label="Require Reviews"
                checked={@configuration.require_reviews}
              />
              <.toggle_field
                name="require_unit_tests"
                label="Require Unit Tests"
                checked={@configuration.require_unit_tests}
              />
            </div>
          </section>

          <section class="card bg-base-200 border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-lg">Analyzer Settings</h2>
              <p class="text-sm opacity-70">What runs at stop time and whether it blocks.</p>

              <div class="divider my-1"></div>

              <.select_field
                name="compile_warnings"
                label="Compile Warnings"
                value={@configuration.compile_warnings}
                modes={@compile_modes}
              />
              <.select_field
                name="credo"
                label="Credo"
                value={@configuration.credo}
                modes={@analyzer_modes}
              />
              <.select_field
                name="exunit"
                label="ExUnit"
                value={@configuration.exunit}
                modes={@analyzer_modes}
              />
              <.select_field
                name="spex"
                label="Spex"
                value={@configuration.spex}
                modes={@analyzer_modes}
              />
              <.select_field
                name="spec_validation"
                label="Spec Validation"
                value={@configuration.spec_validation}
                modes={@analyzer_modes}
              />
              <.select_field
                name="qa_validation"
                label="QA Validation"
                value={@configuration.qa_validation}
                modes={@analyzer_modes}
              />
            </div>
          </section>

          <section class="card bg-base-200 border border-base-300">
            <div class="card-body">
              <h2 class="card-title text-lg">DevOps</h2>
              <p class="text-sm opacity-70">
                Prod is stood up by default; opt out to run UAT-only (story 858).
              </p>

              <div class="divider my-1"></div>

              <.select_field
                name="devops_prod"
                label="Prod Environment"
                value={@configuration.devops_prod}
                modes={[:on, :off]}
              />
            </div>
          </section>

          <div class="flex justify-end">
            <button type="submit" class="btn btn-primary" data-test="save-configuration">
              Save Configuration
            </button>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, required: true

  defp toggle_field(assigns) do
    ~H"""
    <label class="label cursor-pointer justify-between py-2">
      <span class="label-text">{@label}</span>
      <span>
        <input type="hidden" name={"configuration[#{@name}]"} value="false" />
        <input
          type="checkbox"
          name={"configuration[#{@name}]"}
          value="true"
          checked={@checked}
          class="toggle toggle-primary"
          data-test={String.replace(@name, "_", "-")}
        />
      </span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :atom, required: true
  attr :modes, :list, required: true

  defp select_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <div class="label"><span class="label-text">{@label}</span></div>
      <select
        name={"configuration[#{@name}]"}
        class="select select-bordered w-full"
        data-test={String.replace(@name, "_", "-")}
      >
        <option :for={mode <- @modes} value={mode} selected={@value == mode}>
          {format_mode(mode)}
        </option>
      </select>
    </label>
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
  defp format_mode(:on), do: "On"
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
