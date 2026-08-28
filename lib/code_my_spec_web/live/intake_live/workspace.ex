defmodule CodeMySpecWeb.IntakeLive.Workspace do
  @moduledoc """
  Everything after the gate.

  Converts the confirmed plan into an account and project on mount, brings the
  workspace up, and shows it coming up against the phases the container
  actually announces. A boot that fails says so and leaves the plan intact.
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.IntakeComponents

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

      <%!--
        The same conversation, continued. It used to open with its own heading —
        "Now let's decide what it actually does" — over a card-based interview,
        so a visitor who had just confirmed a plan arrived somewhere that looked
        like a different product. Signup sits between the two pages and a
        LiveView cannot survive that navigation, so continuity has to be rebuilt
        rather than kept: both pages derive the same transcript from the same
        plan row.
      --%>
      <.conversation :if={@workspace.status != :failed} transcript={@transcript}>
        <.derived_rules :if={@rules} rules={@rules} />
      </.conversation>

      <%!--
        How far through, kept from the card this replaced. Not decoration: the
        interview promises to pay out within four questions, and a visitor who
        cannot see the end of a conversation does not know it has one.
      --%>
      <p
        :if={@workspace.status != :failed and @turn}
        data-test="interview-progress"
        class="mt-4 text-xs uppercase tracking-[0.18em] text-base-content/50"
      >
        question {length(@answered) + 1} of {Interview.question_cap()}
      </p>

      <.composer
        :if={@workspace.status != :failed and @turn}
        event="answer"
        field="answer"
        rows="2"
        placeholder="In your own words."
      >
        <input type="hidden" name="turn_id" value={@turn && @turn.id} />
      </.composer>

      <p :if={@interview_error} class="text-error text-sm mt-3">{@interview_error}</p>

      <%!--
        What to run, for a visitor who chose their own machine. There is no
        container to watch, so the ambient strip is replaced by the one thing
        they need — and it is the same command a generated application onboards
        itself with, not a special path for this case.
      --%>
      <div
        :if={@workspace.status == :local}
        data-test="local-instructions"
        class="border border-base-300 rounded p-4"
      >
        <p class="text-sm font-medium mb-2">Run it on your machine</p>
        <p class="text-sm opacity-70 mb-3">
          Your project is ready. Bring it up wherever you keep your code:
        </p>
        <pre class="bg-base-200 rounded p-3 text-xs overflow-x-auto"><code>{local_commands(@plan)}</code></pre>
      </div>

      <.boot_status
        :if={@workspace.status not in [:failed, :local]}
        workspace={@workspace}
        app_state={@app_state}
      />
    </div>
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
        <a
          href={Workspaces.url(@workspace)}
          target="_blank"
          rel="noopener"
          class="btn btn-sm btn-primary"
        >
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

  # Nothing is booted for a visitor who chose to run it themselves. The project
  # and its persona are still created — that is what they signed up for — but a
  # container on our box would be one nobody asked for and nobody would open.
  defp mount_workspace(socket, %Scope{} = scope, %{location: :local} = plan) do
    with {:ok, plan} <- Intake.convert(plan, scope),
         {:ok, scope} <- select_plan_scope(scope, plan) do
      socket
      |> assign(page_title: "Your project")
      |> assign(scope: scope, plan: plan)
      |> assign_local()
      |> assign_interview(plan)
    else
      {:error, reason} -> failed_to_start(socket, scope, plan, reason)
    end
  end

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

  # A workspace-shaped nothing. The page reads `@workspace.status` in several
  # places and a nil here would crash the render rather than show the local
  # path — and `:local` is a real status, not a failure, so it must not fall
  # into the `:failed` branch either.
  # Built here rather than inline, because a heredoc indented inside markup is
  # a compiler warning and a heredoc outdented to satisfy the compiler is
  # unreadable markup.
  defp local_commands(plan) do
    """
    mix cms.new #{plan.project_name}
    cd #{plan.project_name}
    mix harness.onboard
    """
  end

  defp assign_local(socket) do
    socket
    |> assign(:workspace, %{status: :local})
    |> assign(:app_state, :local)
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
    |> assign_transcript()
  end

  # Everything said across both pages, rebuilt from the plan row. The shaping
  # turns before signup and the interview turns after it are the same shape,
  # because to the visitor they are the same conversation — the split exists
  # because signup is between them, not because the questions differ.
  defp assign_transcript(socket) do
    %{plan: plan, answered: answered, turn: turn} = socket.assigns

    turns = Enum.map(answered, &%{question: &1.question, answer: &1.answer})

    assign(socket, :transcript, Intake.transcript(plan, turns, turn && turn.question))
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
