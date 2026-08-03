defmodule CodeMySpecWeb.IntakeLive.Workspace do
  @moduledoc """
  Everything after the gate.

  Converts the confirmed plan into an account and project on mount, brings the
  workspace up, and shows it coming up against the phases the container
  actually announces. A boot that fails says so and leaves the plan intact.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.{Intake, UserPreferences, Workspaces}
  alias CodeMySpec.Users.Scope
  alias CodeMySpecWeb.Plugs.IntakeSession

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-4 py-12">
      <div class="text-xs uppercase tracking-[0.22em] text-primary mb-4">
        // your workspace
      </div>

      <.failed :if={@workspace.status == :failed} workspace={@workspace} plan={@plan} />

      <%= if @workspace.status != :failed do %>
        <h1 class="text-3xl font-bold mb-2">Now let's decide what it actually does.</h1>
        <p class="text-base-content/70 mb-6">
          Your application is being built while we talk. A few questions and you'll see the rules
          I derived from your answers.
        </p>

        <.interview_placeholder />
        <.boot_status workspace={@workspace} />
      <% end %>
    </div>
    """
  end

  # The interview itself is the next component. It needs the LLM call path,
  # which is not on main yet, so this is deliberately a seam rather than a
  # pretend conversation.
  defp interview_placeholder(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-6">
      <div class="card-body">
        <p class="text-base-content/70">The story interview starts here.</p>
      </div>
    </div>
    """
  end

  # A strip, not a page. The visitor watches the conversation; the boot is
  # ambient. Watching a bar is what makes a slow boot feel slow.
  defp boot_status(assigns) do
    ~H"""
    <div class="border border-base-300 rounded p-4">
      <div :if={@workspace.status == :booting} class="flex items-center gap-3 mb-2">
        <span class="loading loading-spinner loading-xs text-primary"></span>
        <span class="text-sm">{Workspaces.progress_label(@workspace)}</span>
      </div>

      <div :if={@workspace.status == :running} class="flex items-center justify-between gap-3">
        <span class="text-sm font-medium">It's running.</span>
        <a href={Workspaces.url(@workspace)} target="_blank" rel="noopener" class="btn btn-sm btn-primary">
          Open your application
        </a>
      </div>

      <progress
        :if={@workspace.status == :booting}
        class="progress progress-primary w-full"
        value={Workspaces.progress(@workspace)}
        max="100"
      >
      </progress>
    </div>
    """
  end

  defp failed(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold mb-2">Your workspace didn't come up.</h1>

    <div class="alert alert-error my-6">
      <span>{@workspace.error}</span>
    </div>

    <p class="text-base-content/70 mb-6">
      Your plan is safe — nothing you told us is lost. Trying again picks up where this left off.
    </p>

    <.button phx-click="retry" class="btn-primary">Try again</.button>
    """
  end

  def mount(_params, session, socket) do
    scope = socket.assigns.current_scope
    plan = session |> Map.fetch!(IntakeSession.session_key()) |> Intake.get_plan()

    {:ok, mount_workspace(socket, scope, plan)}
  end

  # No plan on this session — there is nothing to bring up, so send them to
  # the front of the flow rather than showing an empty workspace.
  defp mount_workspace(socket, _scope, nil), do: push_navigate(socket, to: ~p"/build")

  defp mount_workspace(socket, %Scope{} = scope, plan) do
    with {:ok, plan} <- Intake.convert(plan, scope),
         {:ok, scope} <- select_plan_scope(scope, plan),
         {:ok, workspace} <- Workspaces.boot(scope) do
      Workspaces.subscribe_workspace(workspace.project_id)

      socket
      |> assign(page_title: "Your workspace")
      |> assign(scope: scope, plan: plan, workspace: workspace)
    end
  end

  # The plan's account and project become the active ones, so the rest of the
  # app agrees with what the visitor is looking at.
  defp select_plan_scope(%Scope{} = scope, plan) do
    with {:ok, _} <- UserPreferences.select_active_account(scope, plan.account_id),
         {:ok, _} <- UserPreferences.select_active_project(scope, plan.project_id) do
      {:ok, Scope.for_user(scope.user)}
    end
  end

  def handle_event("retry", _params, socket) do
    {:ok, workspace} = Workspaces.boot(socket.assigns.scope)

    {:noreply, assign(socket, :workspace, workspace)}
  end

  # Transitions are recorded where they happen, in Workspaces — this task can
  # finish before the screen has subscribed, so the broadcast only updates.
  def handle_info({event, workspace}, socket)
      when event in [:booting, :progress, :running, :failed] do
    {:noreply, assign(socket, :workspace, workspace)}
  end

  # Leaving while it is still coming up is the signal that decides whether
  # boot time is worth optimising. Recorded here because only the surface
  # knows the visitor went away.
  def terminate(_reason, %{assigns: %{workspace: workspace}}) do
    Workspaces.abandoned(workspace)
  end

  def terminate(_reason, _socket), do: :ok
end
