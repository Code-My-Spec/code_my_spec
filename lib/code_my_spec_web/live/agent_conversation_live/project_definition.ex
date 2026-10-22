defmodule CodeMySpecWeb.AgentConversationLive.ProjectDefinition do
  @moduledoc "Persisted project definition and source choices inside the cockpit's Project panel."
  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Projects.Onboarding
  alias CodeMySpec.Devices

  def update(%{saved_project: project}, socket) do
    cond do
      socket.assigns.project_id != project.id ->
        {:ok, socket}

      socket.assigns.saved_snapshot == {project.onboarding, project.sources} ->
        {:ok, socket}

      socket.assigns.dirty? ->
        {:ok, assign(socket, :external_update?, true)}

      true ->
        {:ok, socket |> assign(saved?: false, error: nil) |> assign_form(project)}
    end
  end

  def update(%{scope: scope} = assigns, socket) do
    socket = assign(socket, assigns)

    if socket.assigns[:project_id] == scope.active_project_id do
      {:ok, socket}
    else
      {:ok, project} = Onboarding.fetch(scope)

      {:ok,
       socket
       |> assign(
         project_id: project.id,
         error: nil,
         saved?: false,
         devices: available_devices(scope)
       )
       |> assign_form(project)}
    end
  end

  defp available_devices(scope) do
    local =
      if Application.get_env(:code_my_spec, :env) == :desktop do
        case CmsHarness.Device.recorded_id() do
          id when is_binary(id) -> Devices.get_harness_device(scope, id)
          _ -> nil
        end
      end

    Enum.uniq_by(Enum.reject([local | Devices.list_devices(scope)], &is_nil/1), & &1.id)
  end

  defp assign_form(socket, project) do
    onboarding = project.onboarding
    source = List.first(project.sources)

    values =
      %{
        "description" => (onboarding && onboarding.description) || "",
        "starting_point" => (onboarding && onboarding.starting_point) || "",
        "destination" => (onboarding && onboarding.destination) || "",
        "source_kind" => (source && source.kind) || "github",
        "repository_url" => (source && source.repository_url) || "",
        "path" => (source && source.path) || "",
        "device_id" => (source && source.device_id) || "",
        "ref" => (source && source.ref) || ""
      }
      |> Map.new(fn {key, value} -> {key, to_string(value)} end)

    assign(socket,
      phase: Onboarding.phase(project),
      form: to_form(values, as: "definition"),
      sources: project.sources,
      saved_snapshot: {project.onboarding, project.sources},
      dirty?: false,
      external_update?: false
    )
  end

  def handle_event("change", %{"definition" => values}, socket) do
    # Fields hidden by the previous choice are absent from the browser payload.
    # Preserve their defaults so revealing a source immediately shows its controls.
    values = Map.merge(socket.assigns.form.params, values)

    {:noreply,
     assign(socket, form: to_form(values, as: "definition"), saved?: false, dirty?: true)}
  end

  def handle_event("reload_saved", _params, socket) do
    case Onboarding.fetch(socket.assigns.scope) do
      {:ok, project} ->
        {:noreply, socket |> assign(saved?: false, error: nil) |> assign_form(project)}

      {:error, _} ->
        {:noreply, assign(socket, error: "Could not reload project choices. Please try again.")}
    end
  end

  def handle_event("save", %{"definition" => values}, socket) do
    attrs = %{"onboarding" => Map.take(values, ~w(description starting_point destination))}

    attrs =
      if values["starting_point"] == "existing" do
        source =
          case values["source_kind"] do
            "local" -> Map.take(values, ~w(path device_id)) |> Map.put("kind", "local")
            _ -> Map.take(values, ~w(repository_url ref)) |> Map.put("kind", "github")
          end

        source =
          case socket.assigns.sources do
            [%{id: id} | _] -> Map.put(source, "id", id)
            _ -> source
          end

        others =
          socket.assigns.sources
          |> Enum.drop(1)
          |> Enum.map(fn source ->
            source
            |> Map.from_struct()
            |> Map.drop([:__meta__])
            |> Map.new(fn {k, v} -> {to_string(k), v} end)
          end)

        Map.put(attrs, "sources", [source | others])
      else
        attrs
      end

    case Onboarding.save(socket.assigns.scope, attrs) do
      {:ok, project} ->
        send(self(), {:project_definition_saved, project})
        {:noreply, socket |> assign(error: nil, saved?: true) |> assign_form(project)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket,
           error:
             "Check your choices. Use a GitHub repository URL or an absolute folder path on an accessible device.",
           saved?: false
         )}

      {:error, _} ->
        {:noreply,
         assign(socket,
           error: "Could not save your project choices. Please try again.",
           saved?: false
         )}
    end
  end

  defp next_step(:synopsis), do: "Tell Product briefly what you want to build and who it is for."

  defp next_step(:build_destination),
    do: "Decide with Product whether to start fresh or use existing code, and where to develop."

  defp next_step(:setup_handoff),
    do: "Your initial choices are saved. Product can now hand environment setup to Main."

  defp next_step(:stories),
    do:
      "Main has the setup request. Continue the story interview with Product while setup proceeds."

  def render(assigns) do
    ~H"""
    <section data-test="project-definition" class="space-y-3">
      <h2 class="font-semibold">Definition &amp; setup</h2>
      <ol data-test="onboarding-progress" class="space-y-1 text-sm">
        <li aria-current={@phase == :synopsis && "step"}>1. Project synopsis</li>
        <li aria-current={@phase == :build_destination && "step"}>
          2. Choose how and where to build
        </li>
        <li aria-current={@phase == :setup_handoff && "step"}>3. Hand environment setup to Main</li>
        <li aria-current={@phase == :stories && "step"}>4. Interview for stories</li>
      </ol>
      <p data-test="onboarding-next" class="text-sm">{next_step(@phase)}</p>
      <p class="text-sm opacity-70">
        Talk with product about what you want to build. Your choices here stay with the project.
      </p>
      <div :if={@external_update?} role="status" data-test="definition-updated" class="text-sm">
        Project choices changed. Your unsaved edits are still here.
        <button type="button" phx-click="reload_saved" phx-target={@myself} class="link">Reload saved choices</button>
      </div>
      <.form
        for={@form}
        id="project-definition-form"
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
        class="space-y-3"
      >
        <.input field={@form[:description]} type="textarea" label="What are we building?" />
        <.input
          field={@form[:starting_point]}
          type="select"
          label="Starting point"
          prompt="Choose a starting point"
          options={[{"A fresh project", "new"}, {"Existing code", "existing"}]}
        />
        <div :if={@form[:starting_point].value == "existing"} class="space-y-3">
          <.input
            field={@form[:source_kind]}
            type="select"
            label="Source"
            options={[{"GitHub repository", "github"}, {"Folder on a connected device", "local"}]}
          />
          <div :if={@form[:source_kind].value == "github"} class="space-y-2">
            <.input
              field={@form[:repository_url]}
              type="url"
              label="Repository URL"
              placeholder="https://github.com/owner/repository"
            />
            <.input field={@form[:ref]} label="Branch or tag (optional)" />
            <p class="text-xs opacity-70">
              Public code can be inspected without signing in. For private code,
              <.link navigate={~p"/app/users/settings"} class="link">connect GitHub</.link>
              with access to the repository.
            </p>
          </div>
          <div :if={@form[:source_kind].value == "local"} class="space-y-2">
            <.input
              field={@form[:device_id]}
              type="select"
              label="Device"
              prompt="Choose a device"
              options={Enum.map(@devices, &{Devices.Device.display_name(&1), &1.id})}
            />
            <.input
              field={@form[:path]}
              label="Folder path"
              placeholder="Absolute path on the selected device"
            />
            <p :if={@devices == []} class="text-xs opacity-70">
              Connect a device before selecting a local folder.
            </p>
          </div>
        </div>
        <.input
          field={@form[:destination]}
          type="select"
          label="Where would you like to develop?"
          prompt="Decide with product"
          options={[
            {"On my device", "local"},
            {"Managed cloud", "cloud"},
            {"Another execution host", "external"}
          ]}
        />
        <p :if={@error} role="alert" class="text-sm text-error">{@error}</p>
        <p :if={@saved?} role="status" class="text-sm text-success">Project choices saved.</p>
        <button class="btn btn-primary btn-sm" type="submit">Save choices</button>
      </.form>
      <p class="text-xs opacity-60">
        Selecting source code does not modify it. Main handles environment setup.
      </p>
    </section>
    """
  end
end
