defmodule CodeMySpecWeb.IntakeLive.Workspace do
  @moduledoc """
  Everything after the gate.

  Converts the confirmed plan into an account and project on mount, brings the
  workspace up, and shows it coming up against the phases the container
  actually announces. A boot that fails says so and leaves the plan intact.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.{Intake, UserPreferences, Workspaces}
  alias CodeMySpec.Intake.Interview
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Workspaces.Workspace

  require Logger
  alias CodeMySpecWeb.Plugs.IntakeSession

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-4 py-12">
      <div class="text-xs uppercase tracking-[0.22em] text-primary mb-4">
        // your workspace
      </div>

      <.failed :if={@workspace.status == :failed} workspace={@workspace} />

      <%= if @workspace.status != :failed do %>
        <h1 class="text-3xl font-bold mb-2">Now let's decide what it actually does.</h1>
        <p class="text-base-content/70 mb-6">
          Your application is being built while we talk. A few questions and you'll see the rules
          I derived from your answers.
        </p>
      <% end %>

      <%!-- The interview outlives the boot. A workspace that dies is a reason
            to retry the workspace, not to throw away a conversation the visitor
            has already spent time on. --%>
      <.interview
        turn={@turn}
        answered={@answered}
        rules={@rules}
        interview_error={@interview_error}
      />

      <.boot_status
        :if={@workspace.status != :failed}
        workspace={@workspace}
        app_state={@app_state}
      />
    </div>
    """
  end

  defp interview(assigns) do
    ~H"""
    <div class="card bg-base-200 mb-6">
      <div class="card-body">
        <div :for={turn <- @answered} class="mb-4">
          <p class="text-sm text-base-content/60">{turn.question}</p>
          <p class="font-medium">{turn.answer}</p>
        </div>

        <.interview_question :if={@turn} turn={@turn} answered={@answered} />
        <.derived_rules :if={@rules} rules={@rules} />
        <p :if={@interview_error} class="text-error text-sm">{@interview_error}</p>
      </div>
    </div>
    """
  end

  defp interview_question(assigns) do
    ~H"""
    <p class="text-xs uppercase tracking-[0.18em] text-base-content/50 mb-2">
      question {length(@answered) + 1} of {Interview.question_cap()}
    </p>
    <p class="text-lg mb-3">{@turn.question}</p>

    <form phx-submit="answer">
      <input type="hidden" name="turn_id" value={@turn.id} />
      <textarea
        name="answer"
        rows="3"
        required
        autofocus
        class="textarea textarea-bordered w-full"
        placeholder="In your own words."
      ></textarea>
      <.button class="btn-primary mt-3">Next</.button>
    </form>
    """
  end

  defp derived_rules(assigns) do
    ~H"""
    <p class="text-xs uppercase tracking-[0.18em] text-primary mb-2">// the rules I derived</p>
    <ul class="list-disc pl-5 space-y-1">
      <li :for={rule <- @rules}>{rule}</li>
    </ul>
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

      <%!--
        Asked, not inferred from the stored column. A container that is up and
        raising answers the proxy just as readily as a healthy one, so "it's
        running" was true of an app that did nothing but 500.
      --%>
      <div
        :if={@workspace.status == :running and @app_state == :running}
        class="flex items-center justify-between gap-3"
      >
        <span class="text-sm font-medium">It's running.</span>
        <a href={Workspaces.url(@workspace)} target="_blank" rel="noopener" class="btn btn-sm btn-primary">
          Open your application
        </a>
      </div>

      <div
        :if={@workspace.status == :running and @app_state == :broken}
        class="flex items-center justify-between gap-3"
      >
        <span class="text-sm font-medium text-error">
          It's up, but the app is erroring.
        </span>
        <a href={Workspaces.url(@workspace)} target="_blank" rel="noopener" class="btn btn-sm">
          See the error
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

    <p class="text-base-content/70 mb-4">
      Your plan is safe — nothing you told us is lost, and the conversation below is still yours.
      Trying again picks up where this left off.
    </p>

    <.button phx-click="retry" class="btn-primary mb-6">Try again</.button>
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

      # Subscribe, then re-read. The watcher starts inside boot/1 and can
      # record a phase before this process is subscribed; since an unchanged
      # step is never re-broadcast, that lost message would leave the bar
      # showing "Getting ready" for the rest of the boot.
      workspace = Workspaces.reload(workspace) || workspace

      socket
      |> assign(page_title: "Your workspace")
      |> assign(scope: scope, plan: plan)
      |> assign_workspace(workspace)
      |> assign_interview(plan)
    else
      # A boot that never starts is still a boot that failed, and the visitor
      # has to be told. Returning the bare error tuple here crashed mount/3
      # with an ArgumentError instead — a white page at exactly the moment the
      # story says they must be told what happened and keep their plan.
      {:error, reason} -> failed_to_start(socket, scope, plan, reason)
    end
  end

  defp failed_to_start(socket, scope, plan, reason) do
    Logger.error("[IntakeLive.Workspace] could not start a workspace: #{inspect(reason)}")

    socket
    |> assign(page_title: "Your workspace")
    |> assign(scope: scope, plan: plan)
    |> assign_workspace(%Workspace{
      status: :failed,
      error: "Your workspace could not be started."
    })
    |> assign_interview(plan)
  end

  # The interview is loaded from the plan every time, so a reconnect — or a
  # boot that failed under it — picks up exactly where the visitor left off.
  defp assign_interview(socket, plan) do
    answered = plan |> Interview.turns() |> Enum.filter(& &1.answer)

    socket
    |> assign(:answered, answered)
    |> assign_current(plan)
  end

  defp assign_current(socket, plan) do
    case Interview.current_turn(plan) do
      {:ok, turn} ->
        socket |> assign(turn: turn, rules: nil, interview_error: nil)

      {:done, _turns} ->
        assign_rules(socket, plan)

      {:error, _reason} ->
        assign(socket,
          turn: nil,
          rules: nil,
          interview_error: "The interview isn't available right now."
        )
    end
  end

  defp assign_rules(socket, plan) do
    case Interview.rules(plan) do
      {:ok, rules} ->
        assign(socket, turn: nil, rules: rules, interview_error: nil)

      {:error, _reason} ->
        assign(socket,
          turn: nil,
          rules: nil,
          interview_error: "Couldn't write up the rules just now."
        )
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

  def handle_event("answer", %{"turn_id" => turn_id, "answer" => answer}, socket) do
    turn = Enum.find([socket.assigns.turn], &(&1 && &1.id == turn_id))

    {:ok, _turn} = Interview.answer(turn, answer)

    {:noreply, assign_interview(socket, socket.assigns.plan)}
  end

  def handle_event("retry", _params, socket) do
    {:ok, workspace} = Workspaces.boot(socket.assigns.scope)

    {:noreply, assign_workspace(socket, workspace)}
  end

  # Transitions are recorded where they happen, in Workspaces — this task can
  # finish before the screen has subscribed, so the broadcast only updates.
  def handle_info({event, workspace}, socket)
      when event in [:booting, :progress, :running, :failed] do
    {:noreply, assign_workspace(socket, workspace)}
  end

  # Leaving while it is still coming up is the signal that decides whether
  # boot time is worth optimising. Recorded here because only the surface
  # knows the visitor went away.
  # The stored row and what the app is doing right now are two different
  # facts, and the row cannot answer the second — so they travel together.
  defp assign_workspace(socket, workspace) do
    socket
    |> assign(:workspace, workspace)
    |> assign(:app_state, Workspaces.state(workspace))
  end

  def terminate(_reason, %{assigns: %{workspace: workspace}}) do
    Workspaces.abandoned(workspace)
  end

  def terminate(_reason, _socket), do: :ok
end
