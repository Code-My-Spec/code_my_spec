defmodule CodeMySpecWeb.IntakeLive.Workspace do
  @moduledoc """
  Everything after the gate.

  Converts the confirmed plan into an account and project on mount, brings the
  workspace up, and shows it coming up against the phases the container
  actually announces. A boot that fails says so and leaves the plan intact.
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.ConversationPanels, only: [panels: 1]
  import CodeMySpecWeb.IntakeComponents

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Agents
  alias CodeMySpec.Billing
  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Interview
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Workspaces
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
      <%!--
        Shown on a failed workspace too. The failure screen tells the visitor
        "the conversation below is still yours" and this is that conversation —
        gating it on a healthy workspace made the sentence a lie and threw away
        on screen exactly what the answers are written down to preserve.
      --%>
      <.conversation transcript={@transcript}>
        <.derived_rules :if={@rules} rules={@rules} />
      </.conversation>

      <%!--
        The cockpit's own panel component (story 1033/3425), same as the
        pre-signup screen — the criterion names both `Plan` and `Workspace`
        in scope, and it went missing here for the entire sales+payment
        window, reappearing only once a real project boots.
      --%>
      <.panels
        screen={:narrow}
        open={[]}
        dynamic_view=""
        dynamic_stories={[]}
        dynamic_story={nil}
        dynamic_epics={[]}
        offer={nil}
        activity={[]}
        waiting={[]}
        copies={[]}
        project_id=""
        conversation_id={nil}
        preview_state={:absent}
      />

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
        change="draft"
        draft={@draft}
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

      <.cloud_payment
        :if={@workspace.status == :awaiting_payment}
        client_secret={@client_secret}
        publishable_key={@publishable_key}
        error={@payment_error}
      />

      <.boot_status
        :if={@workspace.status not in [:failed, :local, :awaiting_payment]}
        workspace={@workspace}
        app_state={@app_state}
      />
    </div>
    """
  end

  # A purchase, in plain terms — not a technical setting to configure. The
  # real cost of a cloud copy is not the compute; it is the operational
  # lifecycle of abandoned, unpaid instances, so nothing is provisioned on
  # the shared host until this succeeds. Reuses the same Stripe Payment
  # Element `CheckoutLive` already pays with, wired to the same JS hook.
  defp cloud_payment(assigns) do
    ~H"""
    <div data-test="cloud-payment" class="border border-base-300 rounded p-4">
      <p class="text-sm font-medium mb-1">Running in the cloud is $100/month.</p>
      <p class="text-sm opacity-70 mb-3">
        Pay to bring your working copy up — nothing is provisioned on our servers
        until this goes through.
      </p>

      <div
        :if={@client_secret}
        id="stripe-payment"
        phx-hook="StripePaymentElement"
        phx-update="ignore"
        data-publishable-key={@publishable_key}
        data-client-secret={@client_secret}
      >
        <form id="payment-form">
          <div id="payment-element"></div>
          <button id="payment-submit" class="btn btn-primary mt-4" type="submit">Pay</button>
          <p id="payment-error" class="text-error text-sm mt-2"></p>
        </form>
      </div>

      <p :if={@error} class="text-error text-sm mt-2">{@error}</p>
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
         {:ok, scope} <- select_plan_scope(scope, plan) do
      socket
      |> assign(page_title: "Your workspace")
      |> assign(scope: scope, plan: plan)
      |> assign_interview(plan)
      |> start_cloud_or_gate_on_payment(scope, plan)
    else
      # A boot that never starts is still a boot that failed, and the visitor
      # has to be told. Returning the bare error tuple here crashed mount/3
      # with an ArgumentError instead — a white page at exactly the moment the
      # story says they must be told what happened and keep their plan.
      {:error, reason} -> failed_to_start(socket, scope, plan, reason)
    end
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
  defp start_cloud_or_gate_on_payment(socket, scope, _plan) do
    case Workspaces.get_workspace(scope) do
      nil -> gate_new_cloud_workspace(socket, scope)
      workspace -> assign_workspace(socket, workspace)
    end
  end

  defp gate_new_cloud_workspace(socket, scope) do
    if paid?(scope) do
      boot_workspace(socket, scope)
    else
      case Billing.start_subscription(scope, :pro) do
        {:ok, %{client_secret: secret}} when is_binary(secret) ->
          assign_awaiting_payment(socket, secret, nil)

        # Nothing to collect — a tier change whose proration was a credit,
        # not a charge. Already paid, so boot rather than show a payment
        # form asking for money that is not owed.
        {:ok, %{client_secret: nil}} ->
          boot_workspace(socket, scope)

        {:error, reason} ->
          Logger.error("[IntakeLive.Workspace] could not start payment: #{inspect(reason)}")

          assign_awaiting_payment(
            socket,
            nil,
            "We couldn't start checkout. Refresh the page to try again."
          )
      end
    end
  end

  defp paid?(%Scope{active_account: %Account{plan: plan}}), do: plan in [:light, :pro, :paid]
  defp paid?(%Scope{}), do: false

  defp assign_awaiting_payment(socket, client_secret, error) do
    socket
    |> assign(:client_secret, client_secret)
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
        start_the_conversation(scope)

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

  # The browser confirmed the payment. Stripe has it; the webhook has the
  # last word on the account's plan, same as `CheckoutLive` — this only
  # stops waiting and starts provisioning.
  def handle_event("payment_confirmed", _params, socket) do
    {:noreply, boot_workspace(socket, socket.assigns.scope)}
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
