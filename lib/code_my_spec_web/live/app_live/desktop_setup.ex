defmodule CodeMySpecWeb.AppLive.DesktopSetup do
  @moduledoc "Desktop setup rendering and events for the application overview."
  use CodeMySpecWeb, :live_view

  alias CmsHarness.Setup

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main
        class="mx-auto max-w-3xl space-y-4"
        data-test="desktop-setup"
        data-stage={if @setup_project, do: "project", else: "prerequisites"}
      >
        <.button
          :if={@setup_project}
          phx-click="new_setup_run"
          data-test="set-up-project"
          disabled={@setup_busy}
        >
          Set up a project
        </.button>
        <.header>Set up this machine</.header>
        <section
          :if={@setup_agent}
          data-test="setup-agent-help"
          data-role="main"
          class="card bg-base-100"
        >
          <div class="card-body">
            <h2 class="card-title">Main agent setup help</h2>
            <p>Send the recorded checks to your main agent for installation help.</p>
            <.button
              phx-click="request_setup_help"
              data-test="accept-install-help"
              disabled={@setup_help_busy || @setup_busy || is_nil(@setup_snapshot)}
            >
              Ask for installation help
            </.button>
            <p :if={@setup_help_status} role="status">{@setup_help_status}</p>
            <div
              :for={message <- @setup_agent_messages}
              :if={message.role == :assistant}
              data-test="setup-agent-message"
              data-message-id={message.id}
            >
              <p class="whitespace-pre-wrap">{CodeMySpec.Conversations.Message.text(message)}</p>
            </div>
          </div>
        </section>
        <p :if={is_nil(@setup_agent)} data-test="setup-agent-unavailable" class="alert">
          The main agent is not available right now. You can complete setup using the checks and installation instructions below.
        </p>
        <p :if={@setup_error} role="alert" class="alert alert-error">{@setup_error}</p>
        <.button
          phx-click="check_prerequisites"
          data-test="check-prerequisites"
          disabled={@setup_busy}
        >
          Check prerequisites
        </.button>
        <p :if={@setup_busy} role="status">Checking prerequisites…</p>
        <section
          :for={step <- setup_steps(@setup_snapshot)}
          class="card bg-base-100 border border-base-300"
          data-test="prerequisite"
          data-name={step["key"]}
          data-state={display_state(step)}
        >
          <div
            class="card-body"
            data-test="setup-step"
            data-step={step["key"]}
            data-state={step["state"]}
          >
            <h2 class="card-title">{step["key"]}: {display_state(step)}</h2>
            <pre :for={command <- step["commands"]} class="whitespace-pre-wrap break-words">{command["output"]}</pre>
            <p :if={step["error"]} role="alert">{step["error"]}</p>
            <p :if={step["state"] == "errored"} data-test="install-instructions">
              {instructions(step["key"])}
              <.link
                :if={step["key"] == "pgvector"}
                href="https://github.com/pgvector/pgvector#installation"
                data-test="install-command"
                class="link"
              >
                pgvector installation commands for your platform
              </.link>
            </p>
            <time :if={step["finished_at"]} datetime={step["finished_at"]}>
              {step["finished_at"]}
            </time>
          </div>
        </section>
        <section
          :if={Setup.prerequisites_passed?(@setup_snapshot) && is_nil(@setup_project)}
          class="card bg-base-100"
        >
          <div class="card-body">
            <h2 class="card-title">Choose a project</h2>
            <p :if={@project_error} data-test="link-project-error" role="alert">{@project_error}</p>
            <.form
              for={@create_form}
              id="desktop-create-project"
              data-test="create-project-form"
              phx-submit="create_setup_project"
            >
              <.input field={@create_form[:name]} label="Application name" required />
              <.input
                field={@create_form[:path]}
                id="desktop-create-project-path"
                label="New project directory"
                required
              />
              <.button type="submit" data-test="create-project" disabled={@setup_busy}>
                Create project
              </.button>
            </.form>
            <.form
              for={@link_form}
              id="desktop-link-project"
              data-test="link-project-form"
              phx-submit="link_setup_project"
            >
              <.input
                field={@link_form[:path]}
                id="desktop-link-project-path"
                label="Existing Elixir project directory"
                required
              />
              <.button type="submit" disabled={@setup_busy}>Link project</.button>
            </.form>
          </div>
        </section>
        <section
          :if={@setup_project}
          class="card bg-base-100"
          data-test={if @project_connected, do: "project-connected", else: "project-connecting"}
          data-project-id={@setup_project.id}
          data-path={@setup_project.root}
        >
          <div class="card-body">
            <h2 class="card-title">{@setup_project.name}</h2>
            <p>
              {if @project_connected,
                do: "Project connected",
                else: "Waiting for the local harness connection"}
            </p>
            <.link
              :if={@project_connected}
              navigate={~p"/app/projects/#{@setup_project.id}/agent-conversation"}
              class="link"
            >
              Open project
            </.link>
            <.button
              phx-click="finish_setup"
              data-test="finish-setup"
              disabled={@setup_busy || !@project_connected}
            >
              Finish setup
            </.button>
            <.button :if={!@project_connected} phx-click="refresh_setup_connection">
              Check connection
            </.button>
          </div>
        </section>
        <p
          :if={@setup_snapshot}
          data-test="setup-results-file"
          data-path={@setup_snapshot["results_path"]}
        >
          Results saved to <code>{@setup_snapshot["results_path"]}</code>
        </p>
      </main>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {snapshot, error} = loaded(Setup.status())
    project = recorded_project(snapshot, socket.assigns.current_scope)
    socket = assign_assistance(socket)

    {:ok,
     assign(socket,
       page_title: "Set up this machine",
       setup_snapshot: snapshot,
       setup_error: error,
       setup_busy: false,
       setup_project: project,
       project_connected: connected_project?(project),
       project_error: nil,
       create_form: to_form(%{"name" => "", "path" => ""}, as: "project"),
       link_form: to_form(%{"path" => ""}, as: "project")
     )}
  end

  def handle_event(event, _params, %{assigns: %{setup_busy: true}} = socket)
      when event in [
             "check_prerequisites",
             "create_setup_project",
             "link_setup_project",
             "new_setup_run"
           ],
      do: {:noreply, socket}

  def handle_event("create_setup_project", %{"project" => params}, socket) do
    scope = socket.assigns.current_scope
    path = params["path"] || ""
    name = params["name"] || ""

    {:noreply,
     socket
     |> assign(setup_busy: true, project_error: nil)
     |> start_async(:setup_project, fn ->
       with {:ok, _} <- Setup.generate_project(path, name, []) do
         connect_project(scope, path)
       end
     end)}
  end

  def handle_event("link_setup_project", %{"project" => params}, socket) do
    scope = socket.assigns.current_scope
    path = params["path"] || ""

    {:noreply,
     socket
     |> assign(setup_busy: true, project_error: nil)
     |> start_async(:setup_project, fn -> connect_project(scope, path) end)}
  end

  def handle_event("new_setup_run", _params, socket) do
    case Setup.new_run([]) do
      {:ok, snapshot} ->
        {:noreply,
         assign(socket,
           setup_snapshot: snapshot,
           setup_project: nil,
           project_connected: false,
           setup_error: nil,
           project_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :setup_error, inspect(reason))}
    end
  end

  def handle_event("request_setup_help", _params, socket) do
    case socket.assigns do
      %{
        setup_agent: %{id: id},
        setup_help_busy: false,
        setup_busy: false,
        setup_snapshot: snapshot,
        current_scope: scope
      }
      when is_map(snapshot) ->
        {:noreply,
         socket
         |> assign(setup_help_busy: true, setup_help_status: "Sending setup results…")
         |> start_async(:setup_help, fn ->
           CodeMySpecWeb.AppLive.DesktopSetupAssistance.request(scope, id, snapshot)
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("finish_setup", _params, socket) do
    with false <- socket.assigns.setup_busy,
         %{id: project_id, root: root} <- socket.assigns.setup_project,
         true <- CmsHarness.Projects.connected?(root),
         {:ok, _snapshot} <- Setup.refresh_connection([]),
         {:ok, %{project_id: ^project_id, root: ^root}} <- Setup.handoff([]),
         {:ok, _project} <-
           CodeMySpec.Projects.get_project(socket.assigns.current_scope, project_id) do
      {:noreply, push_navigate(socket, to: ~p"/app/projects/#{project_id}/agent-conversation")}
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :setup_error,
           "Complete the prerequisite checks and connect the project before finishing setup."
         )}
    end
  end

  def handle_event("refresh_setup_connection", _params, socket) do
    {snapshot, error} = loaded(Setup.refresh_connection([]))

    {:noreply,
     assign(socket,
       setup_snapshot: snapshot,
       setup_error: error,
       project_connected: connected_project?(socket.assigns.setup_project)
     )}
  end

  def handle_event("check_prerequisites", _params, socket) do
    owner = self()

    {:noreply,
     socket
     |> assign(setup_busy: true, setup_error: nil)
     |> start_async(:machine_checks, fn -> Setup.check_prerequisites(notify: owner) end)}
  end

  def handle_async(:setup_project, {:ok, {:ok, result}}, socket) do
    project = %{id: result.project.id, name: result.project.name, root: result.working_copy.root}

    {:noreply,
     assign(socket,
       setup_busy: false,
       project_error: nil,
       setup_snapshot: result.snapshot,
       setup_project: project,
       current_scope: result.scope,
       project_connected: connected_project?(project)
     )}
  end

  def handle_async(:setup_project, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, setup_busy: false, project_error: project_error(reason))}
  end

  def handle_async(:setup_project, {:exit, reason}, socket) do
    {:noreply, assign(socket, setup_busy: false, project_error: Exception.format_exit(reason))}
  end

  def handle_async(:setup_help, {:ok, {:ok, status, _message}}, socket) do
    text =
      if status == :queued,
        do: "Setup results queued for the main agent.",
        else: "Setup results sent to the main agent."

    {:noreply, assign(socket, setup_help_busy: false, setup_help_status: text)}
  end

  def handle_async(:setup_help, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       setup_help_busy: false,
       setup_help_status:
         "Could not deliver setup help request: #{inspect(reason)}. You can continue manually."
     )}
  end

  def handle_async(:setup_help, {:exit, reason}, socket) do
    {:noreply,
     assign(socket,
       setup_help_busy: false,
       setup_help_status: "Setup help request failed: #{Exception.format_exit(reason)}"
     )}
  end

  def handle_async(:machine_checks, {:ok, result}, socket) do
    {snapshot, error} = loaded(result)
    {:noreply, assign(socket, setup_snapshot: snapshot, setup_error: error, setup_busy: false)}
  end

  def handle_async(:machine_checks, {:exit, reason}, socket) do
    {:noreply, assign(socket, setup_error: Exception.format_exit(reason), setup_busy: false)}
  end

  def handle_info({:machine_setup, snapshot}, socket),
    do: {:noreply, assign(socket, :setup_snapshot, snapshot)}

  def handle_info({event, %{conversation_id: id}}, socket)
      when event in [:new_message, :message_updated] do
    case socket.assigns.setup_conversation do
      %{id: ^id} = conversation ->
        {:noreply,
         assign(
           socket,
           :setup_agent_messages,
           CodeMySpec.Conversations.list_messages(conversation)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  defp connect_project(scope, path) do
    CodeMySpecWeb.AppLive.DesktopProject.connect(
      scope,
      path,
      CmsHarness.Device.recorded_id()
    )
  end

  defp recorded_project(
         %{
           "operations" => %{
             "connect" => %{"state" => state, "result" => %{"id" => id, "root" => root}}
           }
         },
         scope
       )
       when state in ["done", "pending"] do
    case CodeMySpec.Projects.get_project(scope, id) do
      {:ok, project} -> %{id: project.id, name: project.name, root: root}
      {:error, _} -> nil
    end
  end

  defp recorded_project(_snapshot, _scope), do: nil

  defp assign_assistance(socket) do
    case CodeMySpecWeb.AppLive.DesktopSetupAssistance.available(socket.assigns.current_scope) do
      {:ok, agent, conversation} ->
        if connected?(socket),
          do: CodeMySpec.Conversations.subscribe_conversation(conversation.id)

        assign(socket,
          setup_agent: agent,
          setup_conversation: conversation,
          setup_agent_messages: CodeMySpec.Conversations.list_messages(conversation),
          setup_help_busy: false,
          setup_help_status: nil
        )

      :unavailable ->
        assign(socket,
          setup_agent: nil,
          setup_conversation: nil,
          setup_agent_messages: [],
          setup_help_busy: false,
          setup_help_status: nil
        )
    end
  end

  defp connected_project?(nil), do: false

  defp connected_project?(project) do
    # A relaunch starts no project subtree on its own -- only a hook does,
    # and there is no hook on this page -- so an already-linked project
    # would otherwise show "Waiting for the local harness connection"
    # forever. `ensure_started/1` is idempotent; `observe/2` waits out the
    # join it triggers rather than reporting "connecting" for a link that
    # is already coming back up (4237e512).
    CmsHarness.Projects.ensure_started(project.root)
    CmsHarness.Setup.Connection.observe(project.root, 2_000).connected
  end

  defp project_error({:invalid_elixir_project, _, _}),
    do: "Select an Elixir project directory containing a valid mix.exs."

  defp project_error(reason), do: inspect(reason)

  defp loaded({:ok, snapshot}), do: {snapshot, nil}
  defp loaded(:none), do: {nil, nil}
  defp loaded({:error, reason}), do: {nil, inspect(reason)}
  defp setup_steps(nil), do: []
  defp setup_steps(snapshot), do: snapshot["steps"]

  defp display_state(%{"key" => "pgvector", "state" => "errored", "error" => error}) do
    if String.contains?(error || "", "pgvector is not installed"), do: "missing", else: "failed"
  end

  defp display_state(%{"state" => "errored"}), do: "failed"
  defp display_state(step), do: step["state"]

  defp instructions("postgres"),
    do:
      "Install PostgreSQL and its command-line tools, start the database service, and make psql available on PATH."

  defp instructions("pgvector"),
    do:
      "Install pgvector for your PostgreSQL server version; use the platform instructions at github.com/pgvector/pgvector."

  defp instructions("version_manager"),
    do: "Install mise or asdf and configure Erlang and Elixir."

  defp instructions("erlang"),
    do: "Install Erlang using mise or asdf and make erl available on PATH."

  defp instructions("elixir"),
    do: "Install Elixir using mise or asdf and make elixir available on PATH."

  defp instructions("cms"), do: "Install the CodeMySpec CLI and make cms available on PATH."
  defp instructions("vibium"), do: "Install Vibium and make vibium available on PATH."
end
