defmodule CodeMySpecWeb.IntakeLive.Procedural do
  @moduledoc """
  The same intake, without the conversation.

  For checking the mechanical parts — signup, pricing, provisioning — apart
  from whether the model answers. One form fills the plan in directly
  (`Intake.plan_procedurally/2`), with no `Shaper`/`Conversation` call
  anywhere in it, and from there this joins the exact path a shaped plan
  takes: `/build/sign-up`, then `IntakeLive.Workspace`'s payment and boot.
  Nothing past this page needs to know a visitor skipped the chat —
  `plan.procedural` on the row is the only trace, and `Workspace` reads it to
  land a procedural visitor in the cockpit once their agent is up, rather
  than leaving them on a card watching a boot bar.
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.IntakeComponents, only: [signup_card: 1]

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

        <.signup_card :if={@awaiting_signup?} plan={@plan} />

        <.form
          :if={not @awaiting_signup?}
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
            field={@form[:location]}
            type="select"
            label="Where should it run"
            options={[
              {"In the cloud — nothing to install", "cloud"},
              {"On my machine", "local"}
            ]}
            class="w-full select"
          />

          <.button class="btn-primary w-full">Next</.button>
        </.form>
      </div>
    </div>
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
      {:ok, plan} ->
        {:noreply, socket |> assign_plan(plan) |> confirmed(socket.assigns.current_scope)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
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
    |> assign_new(:awaiting_signup?, fn -> Intake.names_confirmed?(plan) end)
  end
end
