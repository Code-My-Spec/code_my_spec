defmodule CodeMySpecWeb.IntakeLive.Procedural do
  @moduledoc """
  The same intake, without the conversation.

  For checking the mechanical parts — signup, pricing, provisioning — apart
  from whether the model answers, and for a CRO audit that needs a stable,
  reproducible funnel rather than one an LLM answers a little differently
  each run. It asks exactly what the chat conversation asks — who uses it,
  sign-in, separate copies, the account/project names — as a form instead
  of a conversation: fewer fields here would mean an audit was never
  actually looking at what a visitor is asked.

  ## Three steps, and back is real navigation, not a reset

  "Where should it run" used to be a field on the details form, and it is
  not a question a non-technical visitor can answer — self-hosting is not
  something they could act on either way. `Intake.plan_procedurally/2` asks
  whether they are technical instead and leaves `location` nil; the pricing
  step then shows a priced tier card (`Intake.suggested_location/1` picks
  which one is pre-selected), and `Intake.confirm_tier/2` is what actually
  sets it.

  `@step` is its own assign rather than derived fresh from the plan on every
  render, specifically so "back" can work: the plan does not un-confirm a
  tier just because the visitor wants to look at it again, so deriving the
  step from `plan.location == nil` would make "back" from pricing land
  straight back on pricing. Forward transitions still come from the plan
  succeeding a real write (`assign_step_from_plan/1`, used once on mount to
  resume where a reload found them); "back" only ever moves `@step`.

  From there this joins the exact path a shaped plan takes: `/build/sign-up`,
  then `IntakeLive.Workspace`'s payment and boot. Nothing past this page
  needs to know a visitor skipped the chat — `plan.procedural` on the row is
  the only trace, and `Workspace` reads it to land a procedural visitor in
  the cockpit once their agent is up, rather than leaving them on a card
  watching a boot bar.
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.IntakeComponents, only: [signup_card: 1, reset_link: 1]

  alias CodeMySpec.Intake
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.User
  alias CodeMySpecWeb.Plugs.IntakeSession

  def render(assigns) do
    ~H"""
    <div class="flex min-h-dvh items-center justify-center px-4 py-12">
      <div class="w-full max-w-md">
        <div class="mb-4 text-xs uppercase tracking-[0.22em] text-primary">
          // procedural intake
        </div>

        <.signup_card :if={@step == :signup} plan={@plan} />
        <.back :if={@step == :signup} to="pricing" />

        <.tier_card :if={@step == :pricing} plan={@plan} form={@tier_form} />
        <.back :if={@step == :pricing} to="details" />

        <.form
          :if={@step == :details}
          id="intake-details-form"
          for={@form}
          phx-submit="submit"
          phx-change="validate"
          class="border border-base-300 rounded p-4 space-y-3"
        >
          <.input
            field={@form[:account_name]}
            type="text"
            label="Account name"
            class="w-full input"
          />
          <.input
            field={@form[:project_name]}
            type="text"
            label="Project name"
            class="w-full input"
          />
          <.input field={@form[:who_uses]} type="text" label="Who uses it" class="w-full input" />

          <.input
            field={@form[:needs_sign_in]}
            type="select"
            label="People sign in to use it"
            options={[{"Yes", "true"}, {"No", "false"}]}
            class="w-full select"
          />
          <.input
            field={@form[:separate_copies]}
            type="select"
            label="Each business gets its own separate copy"
            options={[{"Yes", "true"}, {"No", "false"}]}
            class="w-full select"
          />
          <.input
            field={@form[:technical]}
            type="select"
            label="Are you technical?"
            options={[{"Yes", "true"}, {"No", "false"}]}
            class="w-full select"
          />

          <.button class="btn-primary w-full">Next</.button>
        </.form>

        <.reset_link />
      </div>
    </div>
    """
  end

  # A plain button rather than folded into each card's own form: going back
  # writes nothing, so it has no business inside a form whose submit does.
  attr :to, :string, required: true

  defp back(assigns) do
    ~H"""
    <button phx-click="back" phx-value-to={@to} class="mt-2 text-sm text-base-content/50 underline">
      ← Back
    </button>
    """
  end

  # Priced, not a generic infra select — "are you technical" only decides
  # which of these two a visitor is shown first; either is a real choice.
  # Cards borrow their shape from the marketing `/pricing` page's own
  # `pricing_tiers/1` (bulleted feature lists) and `CheckoutLive`'s
  # `tier_choice/1` (a real card per tier) rather than the plain radio rows
  # this replaced — a CRO audit of the funnel has to see the same kind of
  # pricing presentation a visitor buying anywhere else on the site sees.
  @tiers [
    %{
      value: "cloud",
      name: "Cloud",
      price: "$100",
      period: "/month + usage",
      tagline: "We host it. Nothing to install.",
      bullets: [
        "Nothing to install — open a link and it's there",
        "We run the agent and the infrastructure",
        "Billed monthly, scales with usage"
      ]
    },
    %{
      value: "local",
      name: "Dev local",
      price: "$25",
      period: "/month",
      tagline: "Bring your own agent. You run it yourself.",
      trial: "7 days free, then $25/month",
      bullets: [
        "Runs on your own machine",
        "Bring your own coding agent",
        "7-day free trial — cancel before it ends and pay nothing"
      ]
    }
  ]

  attr :plan, :map, required: true
  attr :form, :any, required: true

  defp tier_card(assigns) do
    assigns = assign(assigns, :tiers, @tiers)

    ~H"""
    <.form for={@form} phx-submit="confirm_tier" class="space-y-3">
      <p class="font-medium">Pick a plan.</p>

      <div class="grid gap-3 sm:grid-cols-2">
        <.tier_option :for={tier <- @tiers} tier={tier} form={@form} />
      </div>

      <.button class="btn-primary w-full">Next</.button>
    </.form>
    """
  end

  attr :tier, :map, required: true
  attr :form, :any, required: true

  defp tier_option(assigns) do
    ~H"""
    <label class={[
      "flex flex-col gap-2 rounded border p-4 cursor-pointer",
      if(to_string(@form[:location].value) == @tier.value,
        do: "border-primary border-2",
        else: "border-base-300"
      )
    ]}>
      <input
        type="radio"
        name={@form[:location].name}
        value={@tier.value}
        checked={to_string(@form[:location].value) == @tier.value}
        class="radio radio-sm self-start"
      />
      <span class="font-medium">{@tier.name}</span>
      <span>
        <span class="text-2xl font-bold">{@tier.price}</span>
        <span class="text-sm opacity-70">{@tier.period}</span>
      </span>
      <span class="text-sm opacity-70">{@tier.tagline}</span>

      <span :if={@tier[:trial]} class="badge badge-primary badge-sm w-fit">
        {@tier.trial}
      </span>

      <ul class="mt-1 space-y-1 text-sm">
        <li :for={bullet <- @tier.bullets} class="flex gap-2">
          <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />{bullet}
        </li>
      </ul>
    </label>
    """
  end

  def mount(_params, session, socket) do
    token = Map.fetch!(session, IntakeSession.session_key())
    {:ok, plan} = Intake.start_plan(token)

    {:ok,
     socket
     |> assign(page_title: "Build something, procedurally")
     |> assign_plan(plan)
     |> assign_step_from_plan()}
  end

  def handle_event("validate", %{"plan" => attrs}, socket) do
    changeset = Intake.change_procedural(socket.assigns.plan, attrs)
    {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("submit", %{"plan" => attrs}, socket) do
    case Intake.plan_procedurally(socket.assigns.plan, attrs) do
      {:ok, plan} ->
        {:noreply, socket |> assign_plan(plan) |> assign(:step, :pricing)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("confirm_tier", %{"plan" => attrs}, socket) do
    case Intake.confirm_tier(socket.assigns.plan, attrs) do
      {:ok, plan} ->
        {:noreply, socket |> assign_plan(plan) |> confirmed(socket.assigns.current_scope)}

      {:error, changeset} ->
        {:noreply, assign(socket, :tier_form, to_form(changeset))}
    end
  end

  # Writes nothing. The plan already carries whatever was last confirmed on
  # each step — going back and forward again without changing an answer
  # re-submits the same values, which is a no-op write, not data loss.
  def handle_event("back", %{"to" => "details"}, socket),
    do: {:noreply, assign(socket, :step, :details)}

  def handle_event("back", %{"to" => "pricing"}, socket),
    do: {:noreply, assign(socket, :step, :pricing)}

  # Same gate `IntakeLive.Plan` uses: a stranger sees the signup card in this
  # same page, an already-signed-in visitor goes straight through.
  defp confirmed(socket, %Scope{user: %User{}}),
    do: push_navigate(socket, to: ~p"/build/workspace")

  defp confirmed(socket, _scope), do: assign(socket, :step, :signup)

  defp assign_plan(socket, plan) do
    socket
    |> assign(:plan, plan)
    |> assign(:form, to_form(Intake.change_procedural(plan)))
    |> assign(:tier_form, to_form(Intake.change_tier(plan)))
  end

  # Resumes wherever a reload finds the plan. Only used once, on mount —
  # every transition after that is either a real write (submit, confirm_tier)
  # or "back", never a re-derivation from the row.
  defp assign_step_from_plan(socket) do
    step =
      cond do
        Intake.names_confirmed?(socket.assigns.plan) -> :signup
        socket.assigns.plan.status == :planned -> :pricing
        true -> :details
      end

    assign(socket, :step, step)
  end
end
