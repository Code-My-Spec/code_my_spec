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
  alias CodeMySpec.Intake.{Funnel, Plan, Shaper}
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.User
  alias CodeMySpecWeb.Plugs.IntakeSession

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl px-4 py-12">
      <div class="text-xs uppercase tracking-[0.22em] text-primary mb-4">
        // guided intake
      </div>

      <.step_describe :if={@plan.status == :describing} plan={@plan} />
      <.step_answer
        :if={@plan.status == :answering}
        question={@question}
        turns={@turns}
        thinking={@thinking}
      />
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

  # A short conversation, not a questionnaire. The model asks what a person
  # would ask and works out sign-in and tenancy from the answers — those are
  # our questions, and a visitor with an idea has no view on them.
  defp step_answer(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold mb-6">Tell me a bit more.</h1>

    <div class="space-y-4 mb-6">
      <div :for={turn <- @turns} class="space-y-2">
        <div class="chat chat-start">
          <div class="chat-bubble chat-bubble-neutral">{turn.question}</div>
        </div>
        <div class="chat chat-end">
          <div class="chat-bubble chat-bubble-primary">{turn.answer}</div>
        </div>
      </div>

      <div :if={@question} class="chat chat-start">
        <div class="chat-bubble chat-bubble-neutral">{@question}</div>
      </div>
    </div>

    <.form for={%{}} as={:answer} phx-submit="answer" class="flex gap-3">
      <input
        type="text"
        name="answer"
        autofocus
        autocomplete="off"
        class="input input-bordered w-full"
        placeholder="Type your answer"
      />
      <.button class="btn-primary">Send</.button>
    </.form>

    <p :if={@thinking} class="text-sm text-base-content/60 mt-3">Thinking…</p>
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
      These are my guesses. Change anything that's wrong — what you confirm here is what gets built.
    </p>

    <.form for={@form} phx-submit="confirm_names" phx-change="validate_names" class="space-y-4">
      <.input field={@form[:account_name]} type="text" label="Account name" />
      <.input field={@form[:project_name]} type="text" label="Project name" />

      <%!--
        The two conclusions that pick the generators. They used to be prose in
        the card above, which made the most consequential guesses in the plan
        the only ones the visitor could not correct.
      --%>
      <.input
        field={@form[:needs_sign_in]}
        type="select"
        label="People sign in to use it"
        options={[{"Yes", "true"}, {"No", "false"}]}
      />

      <.input
        field={@form[:separate_copies]}
        type="select"
        label="Each business gets its own separate copy"
        options={[{"Yes", "true"}, {"No", "false"}]}
      />

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

    # Straight into the conversation. A description that already says who uses
    # it and how gets no questions at all — the model goes to the plan.
    {:noreply, socket |> assign_plan(plan) |> assign(turns: []) |> shape()}
  end

  # The answer joins the transcript and the whole conversation goes back to the
  # model, which either asks once more or has enough to fill the form.
  def handle_event("answer", %{"answer" => written}, socket) do
    turns = socket.assigns.turns ++ [%{question: socket.assigns.question, answer: written}]

    {:noreply, socket |> assign(turns: turns) |> shape()}
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
         |> push_navigate(to: gate_for(socket.assigns.current_scope))}

      {:error, changeset} ->
        {:noreply, assign(socket, :names_form, to_form(changeset))}
    end
  end

  # The gate is a sign-up for a stranger and nothing at all for someone already
  # signed in. Sending everyone to /users/register meant an existing customer
  # was bounced off it by redirect_if_user_is_authenticated and landed on the
  # marketing site, plan stranded.
  defp gate_for(%Scope{user: %User{}}), do: ~p"/build/workspace"
  defp gate_for(_scope), do: ~p"/users/register"

  # Ask once more, or take what the model inferred and write the plan.
  defp shape(socket) do
    plan = socket.assigns.plan

    case Shaper.shape(plan, socket.assigns.turns) do
      {:ask, question} ->
        assign(socket, question: question, thinking: false)

      {:ok, attrs} ->
        case Intake.answer(plan, attrs) do
          {:ok, plan} -> generate(socket, plan)
          {:error, _} -> unavailable(socket)
        end

      {:error, _reason} ->
        unavailable(socket)
    end
  end

  # No fallback questionnaire. The conversation is the product, so when the
  # model is unreachable the honest thing is to say so rather than hand over
  # the form it replaced.
  defp unavailable(socket) do
    put_flash(socket, :error, "I couldn't think that through. Try again in a moment.")
  end

  defp generate(socket, plan) do
    case Intake.generate_plan(plan) do
      {:ok, plan} ->
        Funnel.plan_reached(:plan_shown, %{plan_id: plan.id})
        assign_plan(socket, plan)

      # Writing the plan is a call to a model, so it can fail for reasons the
      # visitor had nothing to do with. Keep them on what they already gave.
      {:error, _reason} ->
        socket
        |> assign_plan(plan)
        |> put_flash(:error, "That didn't come back. Try again in a moment.")
    end
  end

  defp assign_plan(socket, %Plan{} = plan) do
    socket
    |> assign(:plan, plan)
    |> assign(:turns, Map.get(socket.assigns, :turns, []))
    |> assign(:question, Map.get(socket.assigns, :question))
    |> assign(:thinking, false)
    |> assign(:answers_form, to_form(Plan.answers_changeset(plan, %{})))
    |> assign(:names_form, to_form(Intake.change_names(plan)))
  end
end
