defmodule CodeMySpecWeb.IntakeLive.Plan do
  @moduledoc """
  Everything before the gate, as one conversation.

  The visitor has no account yet and every navigation is a chance to lose them,
  so it is one mount throughout. The plan is written to a row as it goes, and
  the transcript is derived from that row — so leaving and coming back in the
  same browser returns the conversation rather than an empty page.

  ## It was three steps and that was the problem

  Describe, then answer, then plan, each a full-page heading that replaced the
  one before. A visitor who had just typed a paragraph about their idea landed
  on a fresh page headed "Tell me a bit more", which reads as starting over
  rather than as the same conversation continuing. John, looking at it: "it's
  very abrupt — you type in what you want to build and then there's a second
  prompt that's totally obscure."

  The steps still exist underneath as `plan.status`; they decide what the
  composer submits and whether the plan card is shown. What changed is that
  they stopped being pages. The conversation is the product, and the state
  machine was leaking through it.
  """

  use CodeMySpecWeb, :live_view

  import CodeMySpecWeb.IntakeComponents

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.{Funnel, Plan, Shaper}
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Users.User
  alias CodeMySpecWeb.Plugs.IntakeSession

  def render(assigns) do
    ~H"""
    <div class="mx-auto flex min-h-0 w-full max-w-2xl flex-1 flex-col px-4 py-12">
      <div class="text-xs uppercase tracking-[0.22em] text-primary mb-6">
        // guided intake
      </div>

      <%!--
        One transcript, start to finish. It was three steps that replaced each
        other — describe, then a page headed "Tell me a bit more", then a page
        headed "Here's what I think you're building" — and a visitor who had
        just typed a paragraph landed on a fresh heading that read as starting
        over. The conversation is the product here; the steps were an
        implementation detail leaking through the page.
      --%>
      <.conversation transcript={@transcript} thinking={@thinking} trouble={@trouble}>
        <.plan_card :if={@plan.status in [:planned, :converted]} plan={@plan} form={@names_form} />
      </.conversation>

      <.composer
        :if={@plan.status in [:describing, :answering]}
        event={if @plan.status == :describing, do: "describe", else: "answer"}
        field={if @plan.status == :describing, do: "description", else: "answer"}
        rows={if @plan.status == :describing, do: "3", else: "1"}
        placeholder={
          if @plan.status == :describing,
            do:
              "A booking tool for hair salons, so owners can see their week and clients can book themselves in.",
            else: "Type your answer"
        }
      />
    </div>
    """
  end

  # The plan arrives *in* the conversation rather than on a page of its own,
  # and it arrives as fields rather than as prose to be corrected by typing.
  #
  # Both halves are deliberate. In the transcript, because the visitor has been
  # talking this whole time and being handed a form is where that stops. As
  # fields, because what they confirm has to be exactly what gets built —
  # parsing "call it Salon Book instead" out of a sentence puts a model between
  # the visitor and the generator, and a misread name is not recoverable by the
  # time anyone notices.
  attr :plan, :map, required: true
  attr :form, :any, required: true

  defp plan_card(assigns) do
    ~H"""
    <div data-test="intake-plan" class="chat chat-start">
      <div class="chat-bubble chat-bubble-neutral max-w-full">
        <p>Here's what I think you're building.</p>
        <p class="mt-2 opacity-80">{@plan.summary}</p>
        <p class="mt-1 opacity-70">{@plan.first_build}</p>

        <p class="mt-4 text-sm opacity-70">
          These are my guesses — change anything that's wrong. What you confirm
          here is what gets built.
        </p>

        <.form
          for={@form}
          phx-submit="confirm_names"
          phx-change="validate_names"
          class="mt-4 space-y-3"
        >
          <.input field={@form[:account_name]} type="text" label="Account name" />
          <.input field={@form[:project_name]} type="text" label="Project name" />

          <%!--
            The two conclusions that pick the generators. They used to be prose,
            which made the most consequential guesses the only ones the visitor
            could not correct.
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

          <%!--
            Where it runs, asked here because this is the moment before anything
            is provisioned. A development instance is a real container on a real
            box, and this funnel leaks by design — the interview runs during the
            boot precisely because visitors wander off. Starting one for
            everybody who describes an idea spends it on everybody who leaves.
          --%>
          <.input
            field={@form[:location]}
            type="select"
            label="Where should it run"
            options={[
              {"In the cloud — nothing to install", "cloud"},
              {"On my machine", "local"}
            ]}
          />

          <.button class="btn-primary">Looks right — build it</.button>
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
     |> assign(page_title: "Build something")
     |> assign_plan(plan)
     |> resume()}
  end

  # A visitor coming back mid-conversation gets asked something.
  #
  # The turns live in socket assigns, so a reload keeps the plan row and loses
  # the question that was on screen. What is left renders as the description
  # followed by an empty answer box — a box with nothing above it to answer,
  # which is not a state anybody can act on.
  #
  # It was reachable the slow way (reload, reconnect, come back tomorrow) and
  # the fast way: for 25 days the model could not be called at all, so every
  # visitor's plan stopped at `:answering` with no question ever asked, and
  # every return visit rendered this. Fixing the credential does not clear those
  # — the rows are still sitting at `:answering` — so resuming has to be able to
  # pick the conversation back up.
  #
  # Asked *after* mount, not during it. The first version called the model
  # inline here and the model takes the better part of a minute: it blocked the
  # mount past the connect timeout, so the resumed page rendered the failure
  # message instead of the question. Twice over, because a LiveView mounts
  # disconnected and then connected, and both were paying for a call only one of
  # them could use.
  #
  # `connected?/1` for the same reason: the static render has nowhere to put an
  # answer and no socket to receive one.
  defp resume(%{assigns: %{plan: %Plan{status: :answering}, question: nil}} = socket) do
    if connected?(socket) do
      send(self(), :resume_conversation)
      assign(socket, :thinking, true)
    else
      socket
    end
  end

  defp resume(socket), do: socket

  def handle_info(:resume_conversation, socket) do
    {:noreply, shape(socket)}
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
  #
  # Answering it also stops it being the live question. Leaving it assigned put
  # it in the transcript twice — once as the turn it became, and again as the
  # thing still being asked underneath the answer to it.
  def handle_event("answer", %{"answer" => written}, socket) do
    turns = socket.assigns.turns ++ [%{question: socket.assigns.question, answer: written}]

    {:noreply, socket |> assign(turns: turns, question: nil) |> shape()}
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

    # A fresh attempt, so last attempt's trouble stops being on screen.
    socket = assign(socket, :trouble, nil)

    case Shaper.shape(plan, socket.assigns.turns) do
      {:ask, question} ->
        socket
        |> assign(question: question, thinking: false)
        |> assign_transcript()

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
  #
  # Said in the conversation rather than flashed. A flash is a poor place for
  # the only sign that anything happened: on a phone it renders above a page
  # the visitor has scrolled past, and this failure otherwise looks exactly
  # like the page ending — their answer, then nothing, and a box that will
  # fail the same way. The composer stays, because retrying is the right move
  # and the message now says so.
  defp unavailable(socket) do
    socket
    |> assign(
      thinking: false,
      trouble:
        "Sorry — I couldn't think that through just now. Send it again and I'll " <>
          "have another go."
    )
    |> put_flash(:error, "I couldn't think that through. Try again in a moment.")
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
    |> assign(:trouble, Map.get(socket.assigns, :trouble))
    |> assign(:turns, Map.get(socket.assigns, :turns, []))
    |> assign(:question, Map.get(socket.assigns, :question))
    |> assign(:thinking, false)
    |> assign(:answers_form, to_form(Plan.answers_changeset(plan, %{})))
    |> assign(:names_form, to_form(Intake.change_names(plan)))
    |> assign_transcript()
  end

  # Derived in `Intake`, not here, so the workspace page can rebuild the same
  # conversation from the same row after the signup gate has navigated away.
  defp assign_transcript(socket) do
    %{plan: plan, turns: turns, question: question} = socket.assigns

    assign(socket, :transcript, Intake.transcript(plan, turns, question))
  end
end
