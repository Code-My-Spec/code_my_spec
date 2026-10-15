defmodule CodeMySpecWeb.IntakeLive.Workspace do
  @moduledoc """
  Everything after the gate.

  Converts the confirmed plan into an account and project on mount, brings the
  workspace up, and shows it coming up against the phases the container
  actually announces. A boot that fails says so and leaves the plan intact.
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.ConversationPanels, only: [single_panel: 1]
  import CodeMySpecWeb.IntakeComponents

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Accounts.Authorization
  alias CodeMySpec.Agents
  alias CodeMySpec.Billing
  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Interview
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces
  alias CodeMySpec.Workspaces.Workspace

  require Logger
  alias CodeMySpecWeb.Plugs.IntakeSession

  # Full height: chat and its one dynamic card side by side. Needs the bounded
  # flex ancestor so only the transcript scrolls and the composer stays anchored.
  def render(assigns) do
    ~H"""
    <div class="flex h-dvh min-h-0 flex-col">
      <.failed :if={@workspace.status == :failed} workspace={@workspace} />

      <div class="flex min-h-0 flex-1 flex-col lg:flex-row">
        <div class="flex min-h-0 flex-1 flex-col overflow-hidden px-4 py-6 lg:py-12">
          <div class="mx-auto flex min-h-0 w-full max-w-2xl flex-1 flex-col">
            <div class="mb-4 shrink-0 text-xs uppercase tracking-[0.22em] text-primary">
              // your workspace
            </div>

            <%!--
              The same conversation, continued. It used to open with its own
              heading — "Now let's decide what it actually does" — over a
              card-based interview, so a visitor who had just confirmed a plan
              arrived somewhere that looked like a different product. Signup
              sits between the two pages and a LiveView cannot survive that
              navigation, so continuity has to be rebuilt rather than kept:
              both pages derive the same transcript from the same plan row.

              Shown on a failed workspace too. The failure screen tells the
              visitor "the conversation below is still yours" and this is that
              conversation — gating it on a healthy workspace made the
              sentence a lie and threw away on screen exactly what the
              answers are written down to preserve.
            --%>
            <.conversation transcript={@transcript}>
              <.derived_rules :if={@rules} rules={@rules} />
            </.conversation>

            <%!--
              How far through. Not decoration: the interview promises to pay
              out within four questions, and a visitor who cannot see the end
              of a conversation does not know it has one.

              Deliberately not gated on payment — criterion 3404 answers this
              all the way to its derived rules on this same page with nothing
              ever paid, and that is intentional: the interview is real,
              independent work a visitor can do while they decide whether to
              pay, not something unlocked by paying. What was actually
              confusing (66272b59) is that nothing on screen said so — see the
              note above the payment card.
            --%>
            <p
              :if={@workspace.status != :failed and @turn}
              data-test="interview-progress"
              class="mt-4 shrink-0 text-xs uppercase tracking-[0.18em] text-base-content/50"
            >
              question {length(@answered) + 1} of {Interview.question_cap()}
            </p>

            <.composer
              :if={@workspace.status != :failed and @turn}
              event="answer"
              field="answer"
              rows="2"
              placeholder="In your own words."
              change="draft"
              draft={@draft}
            >
              <input type="hidden" name="turn_id" value={@turn && @turn.id} />
            </.composer>

            <p :if={@interview_error} class="mt-3 shrink-0 text-sm text-error">
              {@interview_error}
            </p>

            <%!--
              Procedural only. A real visitor's own workspace is not a test
              run to wipe — `plan.procedural` is exactly the signal that
              distinguishes the two, same as it is for the auto-navigate into
              the cockpit above.
            --%>
            <.reset_link :if={@plan.procedural} />
          </div>
        </div>

        <.dynamic_panel
          :if={@workspace.status != :failed}
          workspace={@workspace}
          plan={@plan}
          app_state={@app_state}
          project_id={@scope.active_project_id}
          client_secret={@client_secret}
          intent_type={@intent_type}
          publishable_key={@publishable_key}
          payment_error={@payment_error}
        />
      </div>
    </div>
    """
  end

  # Exactly one card, chosen by `@workspace.status`, never a tab strip.
  # `single_panel/1` caps it when stacked on a phone, so a tall card (Stripe's
  # payment element) cannot push the chat column to zero height.
  defp dynamic_panel(assigns) do
    ~H"""
    <.single_panel>
      <%!--
        For a visitor who chose their own machine. There is no container to
        watch, so the ambient strip is replaced by the one thing that
        actually tells them something: whether their own already-running
        harness has picked this project up yet. It generates and onboards
        the project itself once it does — see
        `CmsHarness.Projects.Generator` — so there is no walkthrough to type
        any more, only prerequisites and a wait.
      --%>
      <div :if={@workspace.status == :awaiting_harness} data-test="local-instructions">
        <p class="text-sm font-medium mb-2">Waiting for your harness</p>
        <p class="text-sm opacity-70 mb-3">
          Your project is ready. Install and start the CodeMySpec harness on
          your own machine and it will set this project up there
          automatically — nothing to type once it's running. If that's not
          you, the cloud option above needs nothing installed.
        </p>

        <%!--
          Named and linked, not assumed. A visitor with none of this
          installed used to get three shell commands and no way to know why
          the first one failed — no mention of what a terminal even is,
          nothing to click (e2a1d37b). This doesn't detect what's actually on
          their machine — a server-rendered page can't reach into their
          terminal — so it's guidance, not a guarantee; a real
          prerequisite-check flow is a bigger, separate piece of work.
        --%>
        <p class="text-xs font-medium uppercase tracking-[0.14em] text-base-content/50 mb-1">
          You'll need
        </p>
        <ul class="text-sm list-disc pl-5 mb-3 space-y-1">
          <li>
            <a
              href="https://elixir-lang.org/install.html"
              target="_blank"
              rel="noopener"
              class="link"
            >
              Elixir and Erlang/OTP
            </a>
          </li>
          <li>
            <a
              href="https://www.postgresql.org/download/"
              target="_blank"
              rel="noopener"
              class="link"
            >
              PostgreSQL
            </a>, running locally
          </li>
          <li>
            <a href="https://git-scm.com/downloads" target="_blank" rel="noopener" class="link">
              git
            </a>
          </li>
          <li>
            <.link navigate={~p"/install"} class="link">
              The CodeMySpec harness
            </.link>
            , installed and running
          </li>
        </ul>

        <div class="flex items-center gap-3">
          <span class="loading loading-spinner loading-xs text-primary"></span>
          <span class="text-sm opacity-70">Checking for your harness…</span>
        </div>
      </div>

      <div :if={@workspace.status == :onboarded} data-test="local-onboarded">
        <p class="text-sm font-medium mb-2">Your harness has it.</p>
        <p class="text-sm opacity-70 mb-3">
          It's set up and running on your own machine.
        </p>
        <.link
          navigate={~p"/app/projects/#{@project_id}/agent-conversation"}
          data-test="open-project-dashboard"
          class="btn btn-sm btn-primary"
        >
          Talk to your agent
        </.link>
      </div>

      <.payment_card
        :if={@workspace.status == :awaiting_payment}
        plan={@plan}
        client_secret={@client_secret}
        intent_type={@intent_type}
        publishable_key={@publishable_key}
        error={@payment_error}
      />

      <.boot_status
        :if={@workspace.status not in [:failed, :awaiting_harness, :onboarded, :awaiting_payment]}
        workspace={@workspace}
        app_state={@app_state}
        project_id={@project_id}
      />
    </.single_panel>
    """
  end

  # A purchase in plain terms. Nothing is provisioned on the shared host until it
  # succeeds. Local is a trial: a `:setup` intent puts a card on file instead of
  # charging.
  defp payment_card(assigns) do
    ~H"""
    <div data-test="cloud-payment" class="border border-base-300 rounded p-4">
      <.payment_pitch location={@plan.location} />

      <%!--
        Both the conversation above and this card are live and interactive
        at once with nothing saying they're two independent things rather
        than one confusing sequence (66272b59) — the interview keeps going
        whether or not this gets paid (criterion 3404), and this line is the
        whole fix: say that, rather than gate either one on the other.
      --%>
      <p class="text-xs opacity-60 mb-3">
        No rush — you can keep answering above while you decide.
      </p>

      <div
        :if={@client_secret}
        id="stripe-payment"
        phx-hook="StripePaymentElement"
        phx-update="ignore"
        data-publishable-key={@publishable_key}
        data-client-secret={@client_secret}
        data-intent-type={@intent_type}
      >
        <form id="payment-form">
          <div id="payment-element"></div>
          <button id="payment-submit" class="btn btn-primary mt-4" type="submit">
            {if @intent_type == :setup, do: "Start free trial", else: "Pay"}
          </button>
          <p id="payment-error" class="text-error text-sm mt-2"></p>
        </form>
      </div>

      <p :if={@error} class="text-error text-sm mt-2">{@error}</p>
    </div>
    """
  end

  attr :location, :atom, required: true

  defp payment_pitch(%{location: :local} = assigns) do
    ~H"""
    <p class="text-sm font-medium mb-1">7 days free, then $25/month.</p>
    <p class="text-sm opacity-70 mb-3">
      We need a card on file so nothing interrupts you on day 8 — you won't be
      charged until the trial ends.
    </p>
    """
  end

  defp payment_pitch(assigns) do
    ~H"""
    <p class="text-sm font-medium mb-1">Running in the cloud is $100/month.</p>
    <p class="text-sm opacity-70 mb-3">
      Pay to bring your working copy up — nothing is provisioned on our servers
      until this goes through.
    </p>
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

  # A strip, not a page: the boot is ambient, the conversation is the focus.
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
        <div class="flex gap-2">
          <a
            href={Workspaces.url(@workspace)}
            target="_blank"
            rel="noopener"
            class="btn btn-sm"
          >
            Open your application
          </a>
          <%!--
            The only way onboarding itself pointed at the real project dashboard
            and agent conversation used to be back through the marketing
            homepage's own nav — never surfaced here, where a visitor coming
            straight out of paid onboarding actually is. "Open your application"
            opens the *generated app*, which is a different destination.
          --%>
          <.link
            navigate={~p"/app/projects/#{@project_id}/agent-conversation"}
            data-test="open-project-dashboard"
            class="btn btn-sm btn-primary"
          >
            Talk to your agent
          </.link>
        </div>
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

    # Real values only on the awaiting-payment path; every card receives them.
    socket =
      assign(socket,
        client_secret: nil,
        intent_type: nil,
        publishable_key: nil,
        payment_error: nil
      )

    {:ok, mount_workspace(socket, scope, plan)}
  end

  # No plan on this session: back to the front of the flow.
  defp mount_workspace(socket, _scope, nil), do: push_navigate(socket, to: ~p"/build")

  # Both paths are billing-gated: local is a 7-day `:light` trial (SetupIntent),
  # cloud a `:pro` subscription. Only `on_paid` differs: cloud boots a container,
  # local shows run-it-yourself instructions.
  defp mount_workspace(socket, %Scope{} = scope, plan) do
    with :ok <- authorize_plan(scope, plan),
         {:ok, plan} <- Intake.convert(plan, scope),
         {:ok, scope} <- select_plan_scope(scope, plan) do
      socket
      |> assign(page_title: workspace_title(plan))
      |> assign(scope: scope, plan: plan)
      |> assign_interview(plan)
      |> gate_on_payment(scope, plan)
    else
      # Someone else's converted plan: treated as no plan, before anything about it
      # is assigned to the socket.
      {:error, :not_a_member} ->
        push_navigate(socket, to: ~p"/build")

      # A boot that never starts is shown as failed, with the plan kept.
      {:error, reason} ->
        failed_to_start(socket, scope, plan, reason)
    end
  end

  # `intake_token` survives login/logout (`UserAuth.restore_intake_token/2`), so
  # a converted plan is shown only to a member of its account: a shared browser
  # must not hand over someone else's. An unconverted plan has no account yet.
  defp authorize_plan(%Scope{} = scope, %{status: :converted, account_id: account_id})
       when is_binary(account_id) do
    if Authorization.authorize(:read_account, scope, account_id) do
      :ok
    else
      {:error, :not_a_member}
    end
  end

  defp authorize_plan(%Scope{}, _plan), do: :ok

  defp workspace_title(%{location: :local}), do: "Your project"
  defp workspace_title(_plan), do: "Your workspace"

  defp gate_on_payment(socket, scope, %{location: :local}) do
    gate_new_workspace(socket, scope, :light, [trial_days: 7], &assign_local_status/2)
  end

  # Nothing is provisioned on the shared host until payment succeeds. Gated on
  # whether this project already has a workspace, so a reload or mid-checkout
  # account is never asked to pay again.
  defp gate_on_payment(socket, scope, _plan) do
    case Workspaces.get_workspace(scope) do
      nil ->
        gate_new_workspace(socket, scope, :pro, [], &boot_workspace/2)

      workspace ->
        # Every mount subscribes (refresh, reconnect), or the bar freezes.
        Workspaces.subscribe_workspace(workspace.project_id)
        assign_workspace(socket, workspace)
    end
  end

  # `on_paid` runs once the account is entitled; buying the tier is identical
  # for both paths.
  defp gate_new_workspace(socket, scope, tier, opts, on_paid) do
    if paid?(scope) do
      on_paid.(socket, scope)
    else
      case Billing.start_subscription(scope, tier, opts) do
        {:ok, %{client_secret: secret, intent_type: intent_type}} when is_binary(secret) ->
          assign_awaiting_payment(socket, secret, intent_type, nil)

        # A proration credit: nothing to collect, so proceed.
        {:ok, %{client_secret: nil}} ->
          on_paid.(socket, scope)

        {:error, reason} ->
          Logger.error("[IntakeLive.Workspace] could not start payment: #{inspect(reason)}")

          assign_awaiting_payment(
            socket,
            nil,
            :payment,
            "We couldn't start checkout. Refresh the page to try again."
          )
      end
    end
  end

  defp paid?(%Scope{active_account: %Account{plan: plan}}), do: plan in [:light, :pro, :paid]
  defp paid?(%Scope{}), do: false

  defp assign_awaiting_payment(socket, client_secret, intent_type, error) do
    socket
    |> assign(:client_secret, client_secret)
    |> assign(:intent_type, intent_type)
    |> assign(:publishable_key, publishable_key())
    |> assign(:payment_error, error)
    |> assign(:workspace, %{status: :awaiting_payment})
    |> assign(:app_state, :awaiting_payment)
  end

  defp publishable_key do
    Application.get_env(:code_my_spec, CodeMySpec.Billing, [])[:publishable_key] || ""
  end

  defp boot_workspace(socket, scope) do
    case Workspaces.boot(scope) do
      {:ok, workspace} ->
        Workspaces.subscribe_workspace(workspace.project_id)

        # Subscribe, then re-read: the watcher can record a phase before this process
        # subscribes, and an unchanged step is never re-broadcast.
        workspace = Workspaces.reload(workspace) || workspace

        assign_workspace(socket, workspace)

      {:error, reason} ->
        Logger.error("[IntakeLive.Workspace] could not start a workspace: #{inspect(reason)}")

        assign_workspace(socket, %Workspace{
          status: :failed,
          error: "Your workspace could not be started."
        })
    end
  end

  # Once paid, and on every later mount. Onboarded means a working copy exists
  # (some harness ran the onboard task). `most_recent/1`, not `main/1`: nothing
  # marks a first checkout main automatically.
  defp assign_local_status(socket, scope) do
    case WorkingCopies.most_recent(scope) do
      nil ->
        if connected?(socket), do: schedule_local_poll()

        socket
        |> assign(:workspace, %{status: :awaiting_harness})
        |> assign(:app_state, :awaiting_harness)

      _working_copy ->
        # Start the agent now so "Talk to your agent" has one; idempotent.
        start_the_conversation(scope)

        socket
        |> assign(:workspace, %{status: :onboarded})
        |> assign(:app_state, :onboarded)
    end
  end

  # A harness announces on its own heartbeat and generation can take minutes, so
  # poll cheaply until a working copy appears (that branch never reschedules).
  @local_poll :timer.seconds(5)
  defp schedule_local_poll, do: Process.send_after(self(), :poll_local_harness, @local_poll)

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
    socket = assign_new(socket, :draft, fn -> "" end)

    answered = plan |> Interview.turns() |> Enum.filter(& &1.answer)

    socket
    |> assign(:answered, answered)
    |> assign_current(plan)
    |> assign_transcript()
  end

  # Everything said across both pages, rebuilt from the plan row.
  # `Intake.transcript/3` owns ordering, including the pre-signup half; this page
  # supplies only the interview turns and the pending question.
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

  # Starts the main agent without a button: intake was a conversation, and a
  # setup step here undoes that. Best-effort: a failure is logged, and the
  # workspace still appears.
  defp start_the_conversation(scope) do
    case Agents.ensure_main_agent(scope) do
      {:ok, _agent} ->
        :ok

      {:error, reason} ->
        Logger.info("[Intake] no agent started for the new workspace: #{inspect(reason)}")
        :ok
    end
  end

  # The plan's account and project become the active ones, so the rest of the
  # app agrees with what the visitor is looking at.
  defp select_plan_scope(%Scope{} = scope, plan) do
    with {:ok, _} <- UserPreferences.select_active_account(scope, plan.account_id),
         {:ok, _} <- UserPreferences.select_active_project(scope, plan.project_id) do
      {:ok, UserPreferences.scope_for(scope.user)}
    end
  end

  def handle_event("draft", params, socket) do
    {:noreply, assign(socket, :draft, params["answer"] || "")}
  end

  def handle_event("answer", %{"turn_id" => turn_id, "answer" => answer}, socket) do
    turn = Enum.find([socket.assigns.turn], &(&1 && &1.id == turn_id))

    {:ok, _turn} = Interview.answer(turn, answer)

    # Cleared on send; without a rendered value the answer looks unsent.
    {:noreply, socket |> assign(:draft, "") |> assign_interview(socket.assigns.plan)}
  end

  def handle_event("retry", _params, socket) do
    {:ok, workspace} = Workspaces.boot(socket.assigns.scope)

    {:noreply, assign_workspace(socket, workspace)}
  end

  # The browser confirmed payment or the setup intent. The webhook has the last
  # word on the plan; this only stops waiting.
  def handle_event("payment_confirmed", _params, socket) do
    case socket.assigns.plan do
      %{location: :local} ->
        {:noreply, assign_local_status(socket, socket.assigns.scope)}

      _ ->
        {:noreply, boot_workspace(socket, socket.assigns.scope)}
    end
  end

  def handle_event("payment_failed", %{"message" => message}, socket) do
    {:noreply, assign(socket, :payment_error, message)}
  end

  # Transitions are recorded in Workspaces; the broadcast only updates the view.
  def handle_info({event, workspace}, socket)
      when event in [:booting, :progress, :running, :failed] do
    {:noreply, assign_workspace(socket, workspace)}
  end

  # See `schedule_local_poll/0`.
  def handle_info(:poll_local_harness, socket) do
    {:noreply, assign_local_status(socket, socket.assigns.scope)}
  end

  # The stored row and the app's live state travel together.
  defp assign_workspace(socket, workspace) do
    # The agent is asked for once the workspace is `:running` (the harness has
    # joined by then), not at boot, when it fails `:harness_not_connected`.
    # Idempotent on later re-assignments.
    if match?(%Workspace{status: :running}, workspace) do
      start_the_conversation(socket.assigns.scope)
    end

    socket
    |> assign(:workspace, workspace)
    |> assign(:app_state, Workspaces.state(workspace))
    |> dump_into_cockpit(workspace)
  end

  # A procedural visitor skips the conversation: navigate to the cockpit once
  # running (the agent already exists).
  defp dump_into_cockpit(socket, %Workspace{status: :running}) do
    if socket.assigns.plan.procedural do
      push_navigate(
        socket,
        to: ~p"/app/projects/#{socket.assigns.scope.active_project_id}/agent-conversation"
      )
    else
      socket
    end
  end

  defp dump_into_cockpit(socket, _workspace), do: socket

  # Leaving while it is still coming up decides whether boot time is worth
  # optimising; only the surface knows. Placeholder maps (awaiting payment, local)
  # never reach `abandoned/1`.
  def terminate(_reason, %{assigns: %{workspace: %Workspace{} = workspace}}) do
    Workspaces.abandoned(workspace)
  end

  def terminate(_reason, _socket), do: :ok
end
