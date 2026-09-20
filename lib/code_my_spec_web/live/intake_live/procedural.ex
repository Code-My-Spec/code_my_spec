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

  ## Two steps, not one, once the details are in

  "Where should it run" used to be a field on that same form, and it is not
  a question a non-technical visitor can answer — self-hosting is not
  something they could act on either way. `Intake.plan_procedurally/2` asks
  whether they are technical instead and leaves `location` nil; `show_pricing?/1`
  then shows a priced tier card (`Intake.suggested_location/1` picks which one
  is pre-selected), and `Intake.confirm_tier/2` is what actually sets it. Two
  questions a person can each answer, rather than one they can't.

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
    assigns = assign(assigns, :show_pricing?, show_pricing?(assigns))

    ~H"""
    <div class="flex min-h-dvh items-center justify-center px-4 py-12">
      <div class="w-full max-w-md">
        <div class="mb-4 text-xs uppercase tracking-[0.22em] text-primary">
          // procedural intake
        </div>

        <.signup_card :if={@awaiting_signup?} plan={@plan} />

        <.tier_card :if={@show_pricing?} plan={@plan} form={@tier_form} />

        <.form
          :if={not @awaiting_signup? and not @show_pricing?}
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

  # Between the details form and signup: `status == :planned` means the four
  # generator inputs are known, and `location` still nil means the visitor
  # has not confirmed a tier for them yet. `awaiting_signup?` is checked first
  # because it can also be true here — once the tier is confirmed `location`
  # is set and `names_confirmed?/1` flips, and this must stop claiming the
  # pricing step still needs answering.
  defp show_pricing?(%{awaiting_signup?: true}), do: false
  defp show_pricing?(%{plan: %{status: :planned, location: nil}}), do: true
  defp show_pricing?(%{}), do: false

  # Priced, not a generic infra select — "are you technical" only decides
  # which of these two a visitor is shown first; either is a real choice.
  attr :plan, :map, required: true
  attr :form, :any, required: true

  defp tier_card(assigns) do
    ~H"""
    <.form
      for={@form}
      phx-submit="confirm_tier"
      class="border border-base-300 rounded p-4 space-y-3"
    >
      <p class="font-medium">Pick a plan.</p>

      <label class="flex items-start gap-3 border border-base-300 rounded p-3 cursor-pointer">
        <input
          type="radio"
          name={@form[:location].name}
          value="cloud"
          checked={to_string(@form[:location].value) == "cloud"}
          class="radio mt-1"
        />
        <span>
          <span class="font-medium">Cloud — $100/month + usage</span>
          <br />
          <span class="text-sm opacity-70">We host it. Nothing to install.</span>
        </span>
      </label>

      <label class="flex items-start gap-3 border border-base-300 rounded p-3 cursor-pointer">
        <input
          type="radio"
          name={@form[:location].name}
          value="local"
          checked={to_string(@form[:location].value) == "local"}
          class="radio mt-1"
        />
        <span>
          <span class="font-medium">Dev local — $25/month</span>
          <br />
          <span class="text-sm opacity-70">Bring your own agent. You run it yourself.</span>
        </span>
      </label>

      <.button class="btn-primary w-full">Next</.button>
    </.form>
    """
  end

  def mount(_params, session, socket) do
    token = Map.fetch!(session, IntakeSession.session_key())
    {:ok, plan} = Intake.start_plan(token)

    {:ok,
     socket
     |> assign(page_title: "Build something, procedurally")
     |> assign_plan(plan)}
  end

  def handle_event("validate", %{"plan" => attrs}, socket) do
    changeset = Intake.change_procedural(socket.assigns.plan, attrs)
    {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("submit", %{"plan" => attrs}, socket) do
    case Intake.plan_procedurally(socket.assigns.plan, attrs) do
      # No `confirmed/2` here — `location` is still nil, so `show_pricing?/1`
      # takes over the render on its own. The tier is a separate question,
      # asked once the visitor has been through this one.
      {:ok, plan} ->
        {:noreply, assign_plan(socket, plan)}

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

  # Same gate `IntakeLive.Plan` uses: a stranger sees the signup card in this
  # same page, an already-signed-in visitor goes straight through.
  defp confirmed(socket, %Scope{user: %User{}}),
    do: push_navigate(socket, to: ~p"/build/workspace")

  defp confirmed(socket, _scope), do: assign(socket, :awaiting_signup?, true)

  defp assign_plan(socket, plan) do
    socket
    |> assign(:plan, plan)
    |> assign(:form, to_form(Intake.change_procedural(plan)))
    |> assign(:tier_form, to_form(Intake.change_tier(plan)))
    |> assign_new(:awaiting_signup?, fn -> Intake.names_confirmed?(plan) end)
  end
end
