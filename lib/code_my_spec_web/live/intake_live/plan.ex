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

  import CodeMySpecWeb.ConversationPanels, only: [panels: 1]
  import CodeMySpecWeb.IntakeComponents

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.{Conversation, Funnel, Plan}

  require Logger
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
        <%!--
          Always, rather than once the agent has concluded — until the visitor
          has signed up. The card used to appear on `:planned`, which put the
          paperwork downstream of the talking: somebody who would rather type
          than discuss had no way in, and an unreachable model took the form
          down with it. Beside the composer, not instead of it, so filling a
          field in and saying something are two ways of answering the same
          question. Once names are confirmed by a stranger, the sign-up card
          replaces it — the panel holds one thing at a time.
        --%>
        <.signup_card :if={@awaiting_signup?} plan={@plan} />
        <.plan_card :if={not @awaiting_signup?} plan={@plan} form={@names_form} />
      </.conversation>

      <%!--
        The cockpit's own panel component (story 1033/3425) — extracted from
        `AgentConversationLive.Show` so pre-signup renders the same markup and
        behavior post-signup does, given different (here: empty) backing data.
        Nothing is open by default, so `panel_body/1` never runs — there is no
        project yet to show a preview, stories or team activity for.
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

      <.composer
        :if={@plan.status in [:describing, :answering]}
        event={if @plan.status == :describing, do: "describe", else: "answer"}
        field={if @plan.status == :describing, do: "description", else: "answer"}
        change="draft"
        draft={@draft}
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
    assigns = assign(assigns, :concluded, assigns.plan.status in [:planned, :converted])

    ~H"""
    <div data-test="intake-plan" class="chat chat-start">
      <div class="chat-bubble chat-bubble-neutral max-w-full">
        <%!--
          What the card says depends on whether the agent has got anywhere yet,
          because before it has there are no guesses to offer and saying "here's
          what I think you're building" over five empty fields is the agent
          claiming work it has not done.
        --%>
        <p :if={@concluded}>Here's what I think you're building.</p>
        <p :if={not @concluded}>You can fill this in yourself if you'd rather.</p>

        <p :if={@plan.summary} class="mt-2 opacity-80">{@plan.summary}</p>
        <p :if={@plan.first_build} class="mt-1 opacity-70">{@plan.first_build}</p>

        <p :if={@concluded} class="mt-4 text-sm opacity-70">
          These are my guesses — change anything that's wrong. What you confirm
          here is what gets built.
        </p>
        <p :if={not @concluded} class="mt-4 text-sm opacity-70">
          I'll fill it in as we talk. What you confirm here is what gets built,
          whenever you're ready.
        </p>

        <.form
          for={@form}
          phx-submit="confirm_names"
          phx-change="validate_names"
          class="mt-4 space-y-3"
        >
          <%!--
            `text-base-content` on every control, and this is load-bearing rather
            than tidying. daisyUI's `.input` and `.select` set their own
            background — `--color-base-100` — and no colour, so they inherit it
            from whatever encloses them. Here that is `.chat-bubble-neutral`,
            which sets `--color-neutral-content`: the colour meant to sit on the
            dark neutral bubble.

            In dark mode those happen to agree and it reads fine. In light mode
            base-100 is white and neutral-content is near-white, so the plan card
            — the one screen where the visitor confirms what gets built — was
            white on white. Reported from a phone; every screenshot I had taken
            was dark.

            The labels are deliberately left alone: they sit on the bubble, not
            in a field, so the bubble's colour is the right one for them.
          --%>
          <.input
            field={@form[:account_name]}
            type="text"
            label="Account name"
            class="w-full input text-base-content"
          />
          <.input
            field={@form[:project_name]}
            type="text"
            label="Project name"
            class="w-full input text-base-content"
          />

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
            class="w-full select text-base-content"
          />

          <.input
            field={@form[:separate_copies]}
            type="select"
            label="Each business gets its own separate copy"
            options={[{"Yes", "true"}, {"No", "false"}]}
            class="w-full select text-base-content"
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
            class="w-full select text-base-content"
          />

          <.button class="btn-primary">Looks right — build it</.button>
        </.form>
      </div>
    </div>
    """
  end

  # The gate is a card in the same conversation, not a page the visitor is
  # sent to. GitHub, Google and email are offered together — never one at a
  # time — and the names already confirmed are shown, not asked for again:
  # what gets created is exactly what was just typed into the plan card.
  #
  # Email is a plain HTML form rather than `phx-submit`, on purpose: creating
  # the session cookie is a job for a controller, not a LiveView process,
  # which cannot write the session itself. GitHub and Google are plain links
  # for the same reason — both already go through `IntegrationsController`,
  # which this only has to point back at `/build/workspace` afterward.
  attr :plan, :map, required: true

  defp signup_card(assigns) do
    ~H"""
    <div data-test="signup-card" class="chat chat-start">
      <div class="chat-bubble chat-bubble-neutral max-w-full">
        <p>One more thing, and we can start building.</p>

        <div class="mt-3 space-y-2">
          <input
            type="text"
            value={@plan.account_name}
            readonly
            aria-label="Account name"
            class="w-full input text-base-content"
          />
          <input
            type="text"
            value={@plan.project_name}
            readonly
            aria-label="Project name"
            class="w-full input text-base-content"
          />
        </div>

        <div class="mt-4 flex flex-col gap-2">
          <a
            href={~p"/auth/github/login?return_to=/build/workspace"}
            class="btn btn-primary w-full"
          >
            Continue with GitHub
          </a>
          <a href={~p"/auth/google/login?return_to=/build/workspace"} class="btn btn-outline w-full">
            Continue with Google
          </a>
        </div>

        <div class="divider text-xs text-base-content/50">or email</div>

        <.form for={nil} action={~p"/build/sign-up"} method="post" class="flex gap-2">
          <input
            type="email"
            name="user[email]"
            required
            placeholder="you@domain.dev"
            class="input input-bordered flex-1 text-base-content"
          />
          <.button class="btn-secondary">Continue</.button>
        </.form>
      </div>
    </div>
    """
  end

  def mount(_params, session, socket) do
    token = Map.fetch!(session, IntakeSession.session_key())
    {:ok, plan} = Intake.start_plan(token)

    if connected?(socket) do
      Intake.subscribe(plan)

      # A call the row says is out, with nothing running it — a deploy or a
      # crash took the process and its task. Nothing recovered that: the page
      # rendered "Thinking…" and meant it forever.
      Conversation.resume(plan)
    end

    {:ok,
     socket
     |> assign(page_title: "Build something")
     |> assign_plan(plan)}
  end

  # The task finished. Whoever is watching gets the same row, so a second tab
  # and a reloaded first tab agree without either of them having asked.
  def handle_info({:shaped, %Plan{id: id} = plan}, %{assigns: %{plan: %Plan{id: id}}} = socket) do
    {:noreply, assign_plan(socket, plan)}
  end

  def handle_info({:shaped, _other}, socket), do: {:noreply, socket}

  # Both submissions are one thing: the visitor said something.
  #
  # The two names survive because they describe what the visitor is doing at
  # that point, and twenty-odd specs read them. What does not survive is the
  # view deciding what a submission *means* and acting on it — recording the
  # turn, calling the model, assigning the answer. That was the same fact in two
  # places, and the view's copy is the one that goes away on reload.
  #
  # These forward. `Conversation.said/2` reads the plan's own status to know
  # whether it just heard a description or an answer.
  def handle_event("describe", %{"description" => text}, socket), do: said(socket, text)
  def handle_event("answer", %{"answer" => text}, socket), do: said(socket, text)

  def handle_event("validate_names", %{"plan" => attrs}, socket) do
    changeset = Intake.change_names(socket.assigns.plan, attrs)
    {:noreply, assign(socket, :names_form, to_form(Map.put(changeset, :action, :validate)))}
  end

  def handle_event("confirm_names", %{"plan" => attrs}, socket) do
    case Intake.confirm_names(socket.assigns.plan, attrs) do
      {:ok, plan} ->
        Funnel.plan_reached(:names_confirmed, %{plan_id: plan.id})
        socket = assign_plan(socket, plan)

        {:noreply, confirmed(socket, socket.assigns.current_scope)}

      {:error, changeset} ->
        {:noreply, assign(socket, :names_form, to_form(changeset))}
    end
  end

  def handle_event("draft", params, socket) do
    {:noreply, assign(socket, :draft, params["description"] || params["answer"] || "")}
  end

  # Cleared here rather than by rendering an empty value, so the clear is a
  # decision at the one moment the text should leave the box — not a side
  # effect of every patch that happens to redraw the form.
  defp said(socket, text) do
    socket = assign(socket, :draft, "")

    case Conversation.said(socket.assigns.plan, text) do
      {:ok, plan} ->
        if plan.status == :answering and Intake.turns(plan) == [],
          do: Funnel.plan_reached(:described, %{plan_id: plan.id})

        {:noreply, assign_plan(socket, plan)}

      {:error, reason} ->
        Logger.warning("[IntakeLive] the conversation refused a turn: #{inspect(reason)}")
        {:noreply, unavailable(socket)}
    end
  end

  # The gate is a card in this same conversation for a stranger, and nothing
  # at all for someone already signed in. `/users/register` used to be where
  # every visitor went — which bounced an existing customer off it by
  # `redirect_if_user_is_authenticated` and landed them on the marketing
  # site, plan stranded, and cost a stranger the conversation they were
  # already in.
  defp confirmed(socket, %Scope{user: %User{}}),
    do: push_navigate(socket, to: ~p"/build/workspace")

  defp confirmed(socket, _scope), do: assign(socket, :awaiting_signup?, true)

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

  # Trouble is read off the row, so it survives the reload that a failed turn
  # invites. `unavailable/1` set it in assigns, which meant the message existed
  # only in the socket that saw the failure.
  defp trouble_for(%Plan{shaping_status: :failed}) do
    "Sorry — I couldn't think that through just now. Send it again and I'll " <>
      "have another go."
  end

  defp trouble_for(%Plan{}), do: nil

  # Turns and the pending question come off the row, not out of assigns.
  #
  # Carrying them in assigns is what made a reload lose the conversation, and
  # the fix for *that* — re-asking the model on mount — made every reload
  # produce a different question from the same first message. There is nothing
  # to re-ask now: the row remembers, so a reload renders exactly what was on
  # screen and costs nothing.
  defp assign_plan(socket, %Plan{} = plan) do
    socket
    |> assign(:plan, plan)
    |> assign(:turns, Intake.turns(plan))
    |> assign(:question, plan.pending_question)
    |> assign(:thinking, plan.shaping_status == :thinking)
    |> assign(:trouble, trouble_for(plan))
    |> assign_new(:draft, fn -> "" end)
    |> assign_new(:awaiting_signup?, fn -> false end)
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
