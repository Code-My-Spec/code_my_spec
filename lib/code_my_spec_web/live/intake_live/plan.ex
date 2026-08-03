defmodule CodeMySpecWeb.IntakeLive.Plan do
  @moduledoc """
  Everything before the gate.

  Three steps on one mount — describe, answer, plan — because the visitor has
  no account yet and every navigation is a chance to lose them. The plan is
  written to a row as it goes, so leaving and coming back in the same browser
  lands on whichever step they left.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.{Funnel, Plan}
  alias CodeMySpecWeb.Plugs.IntakeSession

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-4 py-12">
      <div class="text-xs uppercase tracking-[0.22em] text-primary mb-4">
        // guided intake
      </div>

      <.step_describe :if={@plan.status == :describing} plan={@plan} />
      <.step_answer :if={@plan.status == :answering} plan={@plan} form={@answers_form} />
      <.step_plan :if={@plan.status in [:planned, :converted]} plan={@plan} form={@names_form} />
    </div>
    """
  end

  defp step_describe(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold mb-2">What do you want to build?</h1>
    <p class="text-base-content/70 mb-6">
      In your own words. No account needed — you'll see a plan before we ask you for anything.
    </p>

    <form phx-submit="describe">
      <textarea
        name="description"
        rows="5"
        required
        autofocus
        class="textarea textarea-bordered w-full"
        placeholder="A booking tool for hair salons, so owners can see their week and clients can book themselves in."
      >{@plan.description}</textarea>
      <.button class="btn-primary mt-4">Continue</.button>
    </form>
    """
  end

  defp step_answer(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold mb-2">Two quick questions.</h1>
    <p class="text-base-content/70 mb-6">These shape what gets built. Neither costs you anything.</p>

    <.form for={@form} phx-submit="answer" class="space-y-6">
      <.input
        field={@form[:needs_sign_in]}
        type="select"
        label="Will people need to sign in to use this?"
        options={[{"Yes — people have their own login", "true"}, {"No — anyone can just use it", "false"}]}
        prompt="Choose one"
      />

      <.input
        field={@form[:separate_copies]}
        type="select"
        label="Is this for one business, or will lots of separate businesses each use their own copy?"
        options={[
          {"Lots of businesses, each with their own copy", "true"},
          {"Just one business — mine", "false"}
        ]}
        prompt="Choose one"
      />

      <.input field={@form[:who_uses]} type="text" label="Roughly who uses this?" />

      <.button class="btn-primary">Show me the plan</.button>
    </.form>
    """
  end

  defp step_plan(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold mb-2">Here's what I think you're building.</h1>

    <div class="card bg-base-200 my-6">
      <div class="card-body">
        <p class="text-lg">{@plan.summary}</p>
        <p class="text-base-content/70 mt-2">{@plan.first_build}</p>
      </div>
    </div>

    <p class="text-base-content/70 mb-4">
      I've guessed at these names. Change anything that's wrong — what you confirm here is what gets created.
    </p>

    <.form for={@form} phx-submit="confirm_names" phx-change="validate_names" class="space-y-4">
      <.input field={@form[:account_name]} type="text" label="Account name" />
      <.input field={@form[:project_name]} type="text" label="Project name" />

      <.button class="btn-primary">Looks right — build it</.button>
    </.form>
    """
  end

  def mount(_params, session, socket) do
    token = Map.fetch!(session, IntakeSession.session_key())
    {:ok, plan} = Intake.start_plan(token)

    {:ok,
     socket
     |> assign(page_title: "Build something")
     |> assign_plan(plan)}
  end

  def handle_event("describe", %{"description" => description}, socket) do
    {:ok, plan} = Intake.describe(socket.assigns.plan, description)
    Funnel.plan_reached(:described, %{plan_id: plan.id})
    {:noreply, assign_plan(socket, plan)}
  end

  def handle_event("answer", %{"plan" => attrs}, socket) do
    with {:ok, plan} <- Intake.answer(socket.assigns.plan, attrs),
         {:ok, plan} <- Intake.generate_plan(plan) do
      Funnel.plan_reached(:plan_shown, %{plan_id: plan.id})
      {:noreply, assign_plan(socket, plan)}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :answers_form, to_form(changeset))}
    end
  end

  def handle_event("validate_names", %{"plan" => attrs}, socket) do
    changeset = Intake.change_names(socket.assigns.plan, attrs)
    {:noreply, assign(socket, :names_form, to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("confirm_names", %{"plan" => attrs}, socket) do
    case Intake.confirm_names(socket.assigns.plan, attrs) do
      {:ok, plan} ->
        Funnel.plan_reached(:names_confirmed, %{plan_id: plan.id})

        {:noreply,
         socket
         |> assign_plan(plan)
         |> push_navigate(to: ~p"/users/register")}

      {:error, changeset} ->
        {:noreply, assign(socket, :names_form, to_form(changeset))}
    end
  end

  defp assign_plan(socket, %Plan{} = plan) do
    socket
    |> assign(:plan, plan)
    |> assign(:answers_form, to_form(Plan.answers_changeset(plan, %{})))
    |> assign(:names_form, to_form(Intake.change_names(plan)))
  end
end
