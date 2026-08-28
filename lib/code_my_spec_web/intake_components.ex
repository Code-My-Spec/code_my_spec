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

  @doc """
  One thing somebody said.

  Sided by who said it, which is the whole reason the transcript carries `from`
  rather than the caller alternating. An interview turn and a shaping turn are
  the same shape here on purpose.
  """
  attr :entry, :map, required: true

  def said(%{entry: %{from: :agent}} = assigns) do
    ~H"""
    <div data-test="intake-said" data-from="agent" class="chat chat-start">
      <div class="chat-bubble chat-bubble-neutral">{@entry.text}</div>
    </div>
    """
  end

  def said(assigns) do
    ~H"""
    <div data-test="intake-said" data-from="visitor" class="chat chat-end">
      <div class="chat-bubble chat-bubble-primary">{@entry.text}</div>
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
    ~H"""
    <div data-test="intake-transcript" class="min-h-0 flex-1 space-y-4 overflow-y-auto">
      <.said :for={entry <- @transcript} entry={entry} />

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
  """
  attr :event, :string, required: true
  attr :field, :string, required: true
  attr :rows, :string, default: "1"
  attr :placeholder, :string, default: "Type your answer"
  attr :rest, :global

  # For anything the form has to carry that the visitor does not type — the
  # interview's turn id, which says which question is being answered.
  slot :inner_block

  def composer(assigns) do
    ~H"""
    <form
      data-test="intake-composer"
      phx-submit={@event}
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
      ></textarea>
      <.button class="btn-primary">Send</.button>
    </form>
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
