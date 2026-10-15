defmodule CodeMySpecWeb.IntakeComponents do
  @moduledoc """
  The conversation a visitor has on their way in.

  Shared by `IntakeLive.Plan` and `IntakeLive.Workspace` because to the visitor
  they are one conversation, and they only stopped being one page because signup
  sits between them — a stranger has to go through `/users/register` and there
  is no way to keep a LiveView mounted across that.

  So continuity is what these components are for. Both pages derive the same
  transcript from the same plan row and render it with the same bubbles, which
  is why the second page can show what was said before it existed.
  """

  use Phoenix.Component
  use CodeMySpecWeb, :verified_routes

  import CodeMySpecWeb.ChatComponents, only: [chat_message: 1]

  @doc """
  One thing somebody said.

  Renders through `ChatComponents.chat_message/1` — the same bubble
  `AgentConversationLive` uses — rather than a hand-rolled one of its own.
  There used to be two: this one drifted to `chat-bubble-neutral` for the
  agent's side while the shared component had since grown markdown
  rendering, a per-message timestamp and a collapse for long turns, none of
  which a visitor mid-interview ever got.

  The outer `data-test="intake-said"`/`data-from` wrapper is kept rather than
  switched to `ChatComponents`' own `data-test="message"` — existing spex
  assert on it (story 990, 1064, 1067), and "which side this landed on" is
  the behavior worth a stable hook, not the component that drew it.

  Sided by who said it, which is the whole reason the transcript carries `from`
  rather than the caller alternating. An interview turn and a shaping turn are
  the same shape here on purpose.
  """
  attr :id, :string, required: true
  attr :entry, :map, required: true

  def said(%{entry: %{from: :agent}} = assigns) do
    ~H"""
    <div data-test="intake-said" data-from="agent">
      <.chat_message
        id={@id}
        role={:assistant}
        own_role={:user}
        label="product"
        text={@entry.text}
      />
    </div>
    """
  end

  def said(assigns) do
    ~H"""
    <div data-test="intake-said" data-from="visitor">
      <.chat_message id={@id} role={:user} own_role={:user} text={@entry.text} />
    </div>
    """
  end

  @doc """
  Everything said so far.

  Takes the list `Intake.transcript/3` derives, so a page that renders this is
  showing the conversation rather than its own memory of it.
  """
  attr :transcript, :list, required: true
  attr :thinking, :boolean, default: false
  attr :trouble, :string, default: nil
  slot :inner_block

  def conversation(assigns) do
    assigns = assign(assigns, :transcript, Enum.with_index(assigns.transcript))

    ~H"""
    <div data-test="intake-transcript" class="min-h-0 flex-1 space-y-4 overflow-y-auto">
      <.said :for={{entry, i} <- @transcript} id={"intake-turn-#{i}"} entry={entry} />

      <div :if={@thinking} data-test="intake-thinking" class="chat chat-start">
        <div class="chat-bubble chat-bubble-neutral opacity-60">Thinking…</div>
      </div>

      <%!--
        Trouble is said in the conversation, in the agent's voice, because that
        is where the visitor is looking.
        It was a flash. On a phone the flash sat off the top of a page the
        visitor had already scrolled, so a failed turn rendered as their answer
        and then nothing — no question, no plan, no error, and a box that would
        fail again. Measured in production: the guided intake had been dead at
        the first turn for 25 days and looked, from the front, like a page that
        had simply stopped.
      --%>
      <div :if={@trouble} data-test="intake-trouble" class="chat chat-start">
        <div class="chat-bubble chat-bubble-error">{@trouble}</div>
      </div>

      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The box the visitor types into, wherever they are in the conversation.

  One composer throughout: the event and the field change with where the
  conversation has got to, and nothing else does. A visitor who has been typing
  into the same box since the first question should not be handed a different
  one because the state machine moved.

  `phx-disable-with` on the button, same as `AgentConversationLive`'s own
  composer: `Conversation.said/2` is a `GenServer.call` and the visible
  reply is a separate async broadcast, so the gap between clicking Send and
  anything changing on screen was silent — no state change at all on the one
  element the visitor had just touched. That silence is what read as "a
  form", not the bubble styling; disabling the button live is what makes a
  fast turn feel like a chat and a slow one feel like it is still working
  rather than stuck.
  """
  attr :event, :string, required: true
  attr :field, :string, required: true
  attr :rows, :string, default: "1"
  attr :placeholder, :string, default: "Type your answer"

  # What is in the box. A rendered value is load-bearing and not obvious:
  # without one the DOM patch has nothing to set, so what the visitor typed
  # survives the submit and sits there looking unsent — and the next thing
  # anyone does is send it again. `AgentConversationLive` carries the same
  # attribute for the same reason, and paid for it first.
  #
  # `@draft` rather than a hardcoded `""` because every broadcast is a patch:
  # the "Thinking…" bubble alone would throw away a half-written answer.
  attr :draft, :string, default: ""
  attr :change, :string, default: nil
  attr :rest, :global

  # For anything the form has to carry that the visitor does not type — the
  # interview's turn id, which says which question is being answered.
  slot :inner_block

  def composer(assigns) do
    ~H"""
    <form
      data-test="intake-composer"
      phx-submit={@event}
      phx-change={@change}
      class="mt-4 flex shrink-0 items-end gap-3"
      {@rest}
    >
      {render_slot(@inner_block)}
      <textarea
        name={@field}
        rows={@rows}
        required
        autofocus
        autocomplete="off"
        class="textarea textarea-bordered w-full"
        placeholder={@placeholder}
      >{@draft}</textarea>
      <.button class="btn-primary" phx-disable-with="Sending…">Send</.button>
    </form>
    """
  end

  @doc """
  The gate. A card in the conversation rather than a page the visitor is sent
  to — GitHub, Google and email offered together, and the names already
  confirmed shown rather than asked for again: what gets created is exactly
  what was just typed into the plan card, or the procedural form.

  Email is a plain HTML form rather than `phx-submit`, on purpose: creating
  the session cookie is a job for a controller, not a LiveView process, which
  cannot write the session itself. GitHub and Google are plain links for the
  same reason — both already go through `IntegrationsController`, which this
  only has to point back at `/build/workspace` afterward.

  Shared by `IntakeLive.Plan` and `IntakeLive.Procedural`: the gate between
  onboarding and signup does not care which door produced the plan.
  """
  attr :plan, :map, required: true

  def signup_card(assigns) do
    ~H"""
    <div data-test="signup-card" class="border border-base-300 rounded p-4">
      <p class="font-medium">One more thing, and we can start building.</p>

      <div class="mt-3 space-y-2">
        <input
          type="text"
          value={@plan.account_name}
          readonly
          aria-label="Account name"
          class="w-full input"
        />
        <input
          type="text"
          value={@plan.project_name}
          readonly
          aria-label="Project name"
          class="w-full input"
        />
      </div>

      <div class="mt-4 flex flex-col gap-2">
        <a href={~p"/auth/github/login?return_to=/build/workspace"} class="btn btn-primary w-full">
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
          class="input input-bordered flex-1"
        />
        <.button class="btn-secondary">Continue</.button>
      </.form>
    </div>
    """
  end

  @doc """
  Wipes a test run of guided intake back to the root — a plain form post,
  like the email signup card, since clearing the session is a controller's
  job a LiveView cannot do itself.

  Not the same as logging out: `UserAuth.log_out_user/1` carries the intake
  token across on purpose, so a real visitor logging out mid-conversation
  does not lose the plan they were building. This exists to lose it on
  purpose — the whole point of resetting is a new plan — so it goes through
  `IntakeResetController` instead.

  Shared by `IntakeLive.Procedural` and `IntakeLive.Workspace`: testing the
  funnel means being able to bail out and start over from wherever the last
  run left off, not only from its first screen.
  """
  def reset_link(assigns) do
    ~H"""
    <.form for={nil} action={~p"/build/reset"} method="post" class="mt-4 text-center">
      <button type="submit" class="text-xs text-base-content/40 underline">
        Reset (testing) — wipe this run and start over
      </button>
    </.form>
    """
  end

  # Local rather than imported from CoreComponents: this module is used by two
  # LiveViews that already import those, and importing them here too would make
  # every caller ambiguous.
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(type)
  slot :inner_block, required: true

  defp button(assigns) do
    ~H"""
    <button class={["btn", @class]} {@rest}>{render_slot(@inner_block)}</button>
    """
  end
end
