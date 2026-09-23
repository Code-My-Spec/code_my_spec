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
  alias CodeMySpec.Agents
  alias CodeMySpec.Authorization
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

  # Full height, chat and its dynamic companion side by side. Neither is new
  # content — this is the same conversation and the same four cards
  # (local-instructions, cloud-payment, boot-status, failed) the single-column
  # version showed — but two defects in how they used to be arranged are gone:
  #
  # 1. The page was plain document flow with no bounded-height flex ancestor,
  #    so `.conversation`'s own `min-h-0 flex-1 overflow-y-auto` and
  #    `.composer`'s own `shrink-0` (both already written for exactly this
  #    shape) did nothing — the whole page scrolled instead of just the
  #    transcript, and the composer scrolled away with everything else rather
  #    than staying anchored.
  # 2. The cockpit's `Preview`/`Project`/`Activity` tab strip was reused here
  #    with `open={[]}` hardcoded and no `toggle_panel` handler on this
  #    LiveView — the tabs rendered but could never open, and clicking one
  #    would have hit no matching `handle_event` clause. Replaced with
  #    `dynamic_panel/1`, which renders exactly the one card the visitor's
  #    current step actually needs, nothing else.
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

  # Exactly one card, chosen by where the visitor is — never a tab strip with
  # nothing behind it. `@workspace.status` is already the single source of
  # truth every other conditional on this page reads from. `single_panel/1`
  # is the same shared component `IntakeLive.Plan` moved to (story 1033/3425
  # — same wrapper identity as the cockpit's own panel, given different
  # backing data), which is also where the sizing lives now: capped and
  # independently scrollable when stacked below chat on a phone, a
  # fixed-width column with no cap beside it on a desk. That cap matters here
  # specifically because a card whose own content is tall (Stripe's payment
  # element, with Link's optional fields expanded) can otherwise claim its
  # full natural height and push the chat column's flex-1 to zero — the chat
  # did not shrink, it vanished.
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

  # A purchase, in plain terms — not a technical setting to configure. The
  # real cost of a cloud copy is not the compute; it is the operational
  # lifecycle of abandoned, unpaid instances, so nothing is provisioned on
  # the shared host until this succeeds. Local is the same card with
  # different words: a trial takes no money today, but still needs a card on
  # file for the charge once it ends, which is exactly what a `:setup`
  # `intent_type` confirms instead of a payment.
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

    # Only the awaiting-payment path ever has a real value for these — every
    # other path (local, booting, running, failed) still renders
    # `dynamic_panel/1`, which now always receives them as attrs regardless of
    # which card inside it actually uses them.
    socket =
      assign(socket,
        client_secret: nil,
        intent_type: nil,
        publishable_key: nil,
        payment_error: nil
      )

    {:ok, mount_workspace(socket, scope, plan)}
  end

  # No plan on this session — there is nothing to bring up, so send them to
  # the front of the flow rather than showing an empty workspace.
  defp mount_workspace(socket, _scope, nil), do: push_navigate(socket, to: ~p"/build")

  # Local runs nothing on our box — the project and its persona are still
  # created, but a container nobody asked for and nobody would open is not
  # what "run it yourself" means — while cloud boots one once paid. Both are
  # billing-gated the same way now: a 7-day trial of `:light` for local (the
  # visitor still has to hand over a card so the renewal after the trial has
  # something to bill, via a SetupIntent rather than a charge), a straight
  # `:pro` subscription for cloud. Only what happens once paid differs, which
  # is `on_paid` below.
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
      # A stale token pointing at someone else's converted plan — treated
      # exactly like no plan at all (same redirect as the `nil` clause
      # above), and deliberately *before* anything about the plan is
      # assigned to the socket: not the account, not the project, not even
      # the conversation transcript is a stranger's to see, and
      # `failed_to_start/4` below would have shown all three.
      {:error, :not_a_member} ->
        push_navigate(socket, to: ~p"/build")

      # A boot that never starts is still a boot that failed, and the visitor
      # has to be told. Returning the bare error tuple here crashed mount/3
      # with an ArgumentError instead — a white page at exactly the moment the
      # story says they must be told what happened and keep their plan.
      {:error, reason} ->
        failed_to_start(socket, scope, plan, reason)
    end
  end

  # `intake_token` is deliberately carried across login/logout — `UserAuth`'s
  # `restore_intake_token/2` — so a visitor who built a plan anonymously does
  # not lose it by signing up. That stops being safe once the plan has
  # converted to a real account: a different signed-in user whose browser
  # still carries the same token (a shared or kiosk browser, or a lingering
  # cookie) must not be handed someone else's account just because the token
  # still resolves. An unconverted plan has no account yet — it becomes this
  # scope's own the moment `Intake.convert/2` runs — so there is nothing to
  # check.
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

  # The real cost of a cloud copy is not the compute — it is the operational
  # lifecycle of abandoned, unpaid instances — so nothing is provisioned on
  # the shared host until payment succeeds. Gated on whether *this project*
  # already has a workspace, not only on the account's plan: an account can
  # be mid-checkout (a client secret handed out, no webhook yet) or the
  # visitor can simply be reloading the page after their workspace already
  # came up, and neither of those is "ask them to pay again". Once a
  # workspace row exists, every later mount just shows it — the same as
  # before this gate existed.
  defp gate_on_payment(socket, scope, _plan) do
    case Workspaces.get_workspace(scope) do
      nil ->
        gate_new_workspace(socket, scope, :pro, [], &boot_workspace/2)

      workspace ->
        # `boot_workspace/2` only subscribes the mount that actually starts
        # the boot. Every later mount of the same project — a manual refresh,
        # or a LiveView reconnect after a network blip, both of which land
        # here — used to assign a static snapshot and then never hear
        # another :progress/:running broadcast, freezing the bar on whatever
        # phase was true at that instant. `PreviewLive.Show` already gets
        # this right by subscribing unconditionally; matching it here.
        Workspaces.subscribe_workspace(workspace.project_id)
        assign_workspace(socket, workspace)
    end
  end

  # `on_paid` is what to do once the account is entitled — boot a container
  # for cloud, just show the local instructions for local — since that is the
  # only place the two paths actually differ; everything about buying the
  # tier itself is identical.
  defp gate_new_workspace(socket, scope, tier, opts, on_paid) do
    if paid?(scope) do
      on_paid.(socket, scope)
    else
      case Billing.start_subscription(scope, tier, opts) do
        {:ok, %{client_secret: secret, intent_type: intent_type}} when is_binary(secret) ->
          assign_awaiting_payment(socket, secret, intent_type, nil)

        # Nothing to collect — a tier change whose proration was a credit,
        # not a charge. Already paid, so proceed rather than show a payment
        # form asking for money that is not owed.
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

        # Subscribe, then re-read. The watcher starts inside boot/1 and can
        # record a phase before this process is subscribed; since an
        # unchanged step is never re-broadcast, that lost message would
        # leave the bar showing "Getting ready" for the rest of the boot.
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

  # Once paid, and on every later mount of the same plan — a manual refresh
  # or a reconnect both land here too, on the same reasoning
  # `gate_on_payment/3`'s cloud clause already gives for re-subscribing
  # rather than assuming the first mount is the only one that matters.
  #
  # There is no container to watch, so "has this been onboarded" is read
  # from the one place that would know: a working copy exists for this
  # project the moment some harness has run `mix harness.onboard` against
  # it, whether that harness is `CmsHarness.Projects.Generator` picking up
  # `Intake.pending_local_projects/1` on its own or a visitor who typed the
  # commands by hand before this existed. `most_recent/1` rather than
  # `main/1`: nothing designates a first checkout `main` automatically, so a
  # project with exactly one working copy and no human having visited the
  # working-copies page yet would read as still-pending forever.
  defp assign_local_status(socket, scope) do
    case WorkingCopies.most_recent(scope) do
      nil ->
        if connected?(socket), do: schedule_local_poll()

        socket
        |> assign(:workspace, %{status: :awaiting_harness})
        |> assign(:app_state, :awaiting_harness)

      _working_copy ->
        # The agent is what "Talk to your agent" needs to already exist —
        # started here rather than left for that click, the same reasoning
        # `assign_workspace/2` already gives for the cloud path, and just as
        # idempotent to call again on a later mount.
        start_the_conversation(scope)

        socket
        |> assign(:workspace, %{status: :onboarded})
        |> assign(:app_state, :onboarded)
    end
  end

  # A harness announces on its own heartbeat (`CmsHarness.WorkingCopyReporter`,
  # every 2 minutes) and generation itself can run for real minutes once it
  # does, so this waits rather than expecting either sooner. Cheap either
  # way — one query against a column already indexed by `project_id` — and
  # stopped the moment `assign_local_status/2` finds a working copy, since
  # that branch never reschedules.
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

  # Everything said across both pages, rebuilt from the plan row. The shaping
  # half (description, pre-signup Q&A, name confirmation) is derived inside
  # `Intake.transcript/3` from `plan` alone, in its real chronological place
  # before the interview — this page only supplies the interview half, which
  # happened after signup and lives on `answered`/`turn` instead of on `plan`.
  # Passing shaping turns through here too used to duplicate the split
  # `Intake.transcript/3` now owns, and once ordering it internally, letting
  # this page pass its own pending question is what put an interview question
  # ahead of the confirmation turn that preceded it (990/3431 follow-up).
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

  # Asked for at boot rather than offered as a button.
  #
  # The visitor has spent the whole of intake in a conversation; landing them on
  # "start an agent" is a setup step at the exact moment the product is meant to
  # be proving it removes them. `boot/1` has already minted the copy and made it
  # main, so there is something to start on before the container answers.
  #
  # Best-effort on purpose. `ensure_main_agent/1` records `:starting` and the
  # machine confirms, so an agent that cannot start yet is an unconfirmed row
  # rather than a workspace that refused to appear — and a visitor with no
  # provider and no platform credential configured still gets their app.
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
      {:ok, Scope.for_user(scope.user)}
    end
  end

  def handle_event("draft", params, socket) do
    {:noreply, assign(socket, :draft, params["answer"] || "")}
  end

  def handle_event("answer", %{"turn_id" => turn_id, "answer" => answer}, socket) do
    turn = Enum.find([socket.assigns.turn], &(&1 && &1.id == turn_id))

    {:ok, _turn} = Interview.answer(turn, answer)

    # Cleared at the one moment the text should leave the box. Without a
    # rendered value the patch has nothing to set, so the answer sits there
    # looking unsent and the obvious next move is to send it again.
    {:noreply, socket |> assign(:draft, "") |> assign_interview(socket.assigns.plan)}
  end

  def handle_event("retry", _params, socket) do
    {:ok, workspace} = Workspaces.boot(socket.assigns.scope)

    {:noreply, assign_workspace(socket, workspace)}
  end

  # The browser confirmed the payment or the trial's setup intent. Stripe has
  # it; the webhook has the last word on the account's plan, same as
  # `CheckoutLive` — this only stops waiting. Cloud starts provisioning; local
  # has nothing to provision, so it just shows the run-it-yourself card.
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

  # Transitions are recorded where they happen, in Workspaces — this task can
  # finish before the screen has subscribed, so the broadcast only updates.
  def handle_info({event, workspace}, socket)
      when event in [:booting, :progress, :running, :failed] do
    {:noreply, assign_workspace(socket, workspace)}
  end

  # A harness announces on its own schedule, not this page's — see
  # `schedule_local_poll/0` for why polling is what asks in between.
  def handle_info(:poll_local_harness, socket) do
    {:noreply, assign_local_status(socket, socket.assigns.scope)}
  end

  # Leaving while it is still coming up is the signal that decides whether
  # boot time is worth optimising. Recorded here because only the surface
  # knows the visitor went away.
  # The stored row and what the app is doing right now are two different
  # facts, and the row cannot answer the second — so they travel together.
  defp assign_workspace(socket, workspace) do
    # Asked for here, not the instant the container is told to boot (issue
    # 9bef58fb). `Workspaces.boot/1` only kicks the container off — at that
    # exact moment the harness inside it cannot possibly have joined
    # `harness_project:<id>` yet, so an agent asked for then failed with
    # `:harness_not_connected` on every fresh cloud onboarding, wrote a
    # `:starting` row, and nothing ever retried it: `list_running/1` treats
    # `:starting` as already handled, and the only path back to `:running`
    # is the harness reporting a launch it was never asked to make. By the
    # time a workspace reaches `:running`, `BootSteps`' own ordering has
    # already run `starting_harness` before `starting_app`, so the harness
    # has very likely joined — and `ensure_main_agent/1` is idempotent, so
    # calling it on every later re-assignment (a reconnect, a reload) costs
    # nothing when an agent already exists.
    if match?(%Workspace{status: :running}, workspace) do
      start_the_conversation(socket.assigns.scope)
    end

    socket
    |> assign(:workspace, workspace)
    |> assign(:app_state, Workspaces.state(workspace))
    |> dump_into_cockpit(workspace)
  end

  # A procedural visitor asked to skip the conversation, not to watch a boot
  # bar instead of one. `start_the_conversation/1` above already started their
  # agent by the time this runs, so there is somewhere real to land them —
  # the same cockpit `boot_status/1`'s own "Talk to your agent" button points
  # at, taken automatically instead of offered.
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

  # `@workspace` is a real `%Workspace{}` once one has been provisioned, but
  # before that — awaiting payment, or the local path, which has no row at
  # all — it's a status-shaped placeholder map so the rest of the template
  # has something to read. `abandoned/1` only knows what to do with a real
  # row, so a visitor who leaves before either happens must not reach it.
  def terminate(_reason, %{assigns: %{workspace: %Workspace{} = workspace}}) do
    Workspaces.abandoned(workspace)
  end

  def terminate(_reason, _socket), do: :ok
end
