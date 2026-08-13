defmodule CodeMySpecWeb.ChatComponents do
  @moduledoc """
  One set of message components for every conversation surface.

  Three views render conversations — the support inbox, the story interview,
  and the record of what an agent did — and each grew its own `turn/1`,
  `chat_side/1` and `chat_bubble/1`. They drifted, as copies do: tool calls
  render slightly differently in two of them, and a tool result is labelled
  `tool-result` in one and `tool-call` in another.

  ## Two things a surface has to say

  **Which side is "mine".** In the support inbox the operator is the reader, so
  the operator's messages sit right. In an agent conversation the reader is
  watching, and the assistant sits right. Same markup, different answer, so it
  is an argument (`own_role`) rather than a hardcoded clause.

  **What `role: :tool` means.** This is not cosmetic. Two writers use that role
  for opposite things: `ConversationRecorder.write_tool_calls/3` writes a tool
  *call* with it, and `Conversations.add_tool_result/4` writes a tool *result*
  with it. A component cannot tell them apart from the message, because the
  difference is not in the message — so the surface says which it is
  (`tool_role`), and the naming stays honest on both.

  That ambiguity is worth fixing in the data rather than carrying here forever.
  Naming it in the API is how it stops being invisible.
  """
  use Phoenix.Component

  import CodeMySpecWeb.CoreComponents, only: [icon: 1]

  alias CodeMySpec.Conversations.Message

  @doc """
  One turn, dispatched on what the message actually carries.

  Order matters: a halted or failed turn is a notice before it is a message,
  and a turn with calls is those calls rather than an empty bubble.
  """
  attr :id, :string, required: true
  attr :message, :any, required: true
  attr :own_role, :atom, default: :assistant, doc: "the role rendered on the right"

  attr :tool_role, :atom,
    values: [:call, :result],
    default: :result,
    doc: "what this surface's `role: :tool` messages are"

  def turn(%{message: %{agent_role: role}} = assigns) when role in ["halted", "failed"] do
    assigns = assign(assigns, :marker, "chat-#{role}")

    ~H"""
    <.notice id={@id} marker={@marker}>{Message.text(@message)}</.notice>
    """
  end

  def turn(%{message: %{tool_calls: calls}} = assigns) when is_list(calls) and calls != [] do
    ~H"""
    <div id={@id} class="space-y-2">
      <.tool_call
        :for={call <- @message.tool_calls}
        name={call["name"]}
        call_id={call["id"]}
        agent_role={@message.agent_role}
      />
    </div>
    """
  end

  # Nothing to show — no text, no calls. Hidden rather than rendered as an
  # empty bubble, and still rendered as an element so the stream has its id.
  def turn(%{message: %{content: [], tool_calls: nil}} = assigns) do
    ~H"""
    <div id={@id} class="hidden"></div>
    """
  end

  def turn(%{message: %{role: :tool}, tool_role: :call} = assigns) do
    ~H"""
    <.tool_call
      id={@id}
      name={Message.text(@message)}
      call_id={@message.tool_call_id}
      agent_role={@message.agent_role}
    />
    """
  end

  def turn(%{message: %{role: :tool}} = assigns) do
    ~H"""
    <.tool_result
      id={@id}
      call_id={@message.tool_call_id}
      agent_role={@message.agent_role}
      text={Message.text(@message)}
    />
    """
  end

  def turn(assigns) do
    ~H"""
    <.chat_message
      id={@id}
      role={@message.role}
      own_role={@own_role}
      label={@message.agent_role}
      sender_id={@message.sender_id}
      text={Message.text(@message)}
    />
    """
  end

  @doc "A person's or an agent's words."
  attr :id, :string, required: true
  attr :role, :atom, required: true
  attr :own_role, :atom, default: :assistant
  attr :label, :string, default: nil
  attr :sender_id, :string, default: nil
  attr :text, :string, required: true

  slot :extra,
    doc:
      "rendered inside the bubble, under the text — attachments, cards, anything the tool returned"

  def chat_message(assigns) do
    ~H"""
    <div
      id={@id}
      data-test="message"
      data-role={@role}
      data-agent-role={@label}
      data-sender-id={@sender_id}
      class={["chat", side(@role, @own_role)]}
    >
      <div :if={@label} class="chat-header text-xs opacity-60">{@label}</div>
      <div class={["chat-bubble break-words", tone(@role, @own_role)]}>
        <%!-- A message can be attachments and nothing else; an empty paragraph
              there renders as a blank line inside the bubble. --%>
        <p :if={@text != ""} class="whitespace-pre-wrap">{@text}</p>
        {render_slot(@extra)}
      </div>
    </div>
    """
  end

  @doc "A call the agent made. The name is the point; arguments are not shown yet."
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :call_id, :string, default: nil
  attr :agent_role, :string, default: nil

  def tool_call(assigns) do
    ~H"""
    <div
      id={@id}
      data-test="tool-call"
      data-tool={@name}
      data-tool-call-id={@call_id}
      data-agent-role={@agent_role}
      data-state="done"
      class="rounded-box bg-base-200 p-3 font-mono text-xs"
    >
      <div :if={@agent_role} class="mb-1 uppercase opacity-60">{@agent_role}</div>
      {@name}
    </div>
    """
  end

  @doc "What a call came back with."
  attr :id, :string, default: nil
  attr :call_id, :string, default: nil
  attr :agent_role, :string, default: nil
  attr :text, :string, required: true

  def tool_result(assigns) do
    ~H"""
    <div
      id={@id}
      data-test="tool-result"
      data-tool-call-id={@call_id}
      data-agent-role={@agent_role}
      class="rounded-box bg-base-200 p-3"
    >
      <div :if={@agent_role} class="mb-1 text-xs uppercase opacity-60">{@agent_role}</div>
      <pre class="whitespace-pre-wrap break-words font-mono text-xs">{@text}</pre>
    </div>
    """
  end

  @doc """
  Something about the conversation rather than in it — halted, failed, or a gap
  in the record. Warning-toned because each one means the transcript is not the
  whole story.
  """
  attr :id, :string, default: nil
  attr :marker, :string, required: true
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div
      id={@id}
      data-test={@marker}
      class="rounded-box border border-warning/40 bg-warning/10 p-3 text-sm"
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A question the agent asked, answerable where it is shown.

  Lifted out of `QuestionLive.Show` unchanged — it was already the right thing
  and had been working; what it lacked was a second place to appear. The plan
  is that a notification takes you to the conversation the question came from,
  so you answer it with the surrounding work visible rather than on a page that
  shows the question and nothing else.

  Answered questions keep rendering, showing what was asked and what was said.
  In a transcript that is the whole point: the answer is part of the record,
  not a modal that closes.

  `on_submit` names the event because the two hosts handle it differently — a
  page that has one question, and a transcript that may have several.
  """
  attr :id, :string, default: nil
  attr :request, :any, required: true, doc: "a %Notifications.QuestionRequest{}"
  attr :on_submit, :string, default: "submit"

  def question(assigns) do
    ~H"""
    <div id={@id} data-test="question-request" data-status={@request.status} class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-chat-bubble-left-right" class="size-5 text-primary" />
          {@request.title || "Claude Code has a question"}
        </h2>

        <div :if={@request.status == "answered"} data-test="question-answered" class="mt-2">
          <div class="alert alert-success">
            <.icon name="hero-check-circle" class="size-5" /> Answer sent.
          </div>
          <dl class="mt-4 space-y-2">
            <div :for={{q, a} <- @request.answers} class="text-sm">
              <dt class="font-semibold opacity-70">{q}</dt>
              <dd>{format_answer(a)}</dd>
            </div>
          </dl>
        </div>

        <form :if={@request.status == "pending"} phx-submit={@on_submit} class="mt-2 space-y-6">
          <fieldset :for={{question, i} <- Enum.with_index(@request.questions)} class="space-y-2">
            <div>
              <span :if={question["header"]} class="badge badge-primary badge-sm">
                {question["header"]}
              </span>
              <p class="mt-1 font-medium">{question["question"]}</p>
            </div>

            <textarea
              :if={free_form?(question)}
              name={"q_#{i}"}
              rows="4"
              placeholder="Type your answer…"
              class="textarea textarea-bordered w-full"
            ></textarea>

            <div :if={not free_form?(question)} class="space-y-2">
              <label
                :for={opt <- question["options"] || []}
                class="flex cursor-pointer items-start gap-3 rounded-box border border-base-300 p-3 hover:bg-base-300/40"
              >
                <input
                  type={input_type(question)}
                  name={field_name(question, i)}
                  value={opt["label"]}
                  class={choice_class(question)}
                />
                <span class="flex flex-col">
                  <span class="font-medium">{opt["label"]}</span>
                  <span :if={opt["description"]} class="text-xs opacity-60">
                    {opt["description"]}
                  </span>
                </span>
              </label>

              <label class="flex cursor-pointer items-center gap-3 rounded-box border border-dashed border-base-300 p-3">
                <input
                  type={input_type(question)}
                  name={field_name(question, i)}
                  value="__other__"
                  class={choice_class(question)}
                />
                <input
                  type="text"
                  name={"q_#{i}_other"}
                  placeholder="Other…"
                  class="input input-bordered input-sm flex-1"
                />
              </label>
            </div>
          </fieldset>

          <button type="submit" class="btn btn-primary w-full">Send answer</button>
        </form>
      </div>
    </div>
    """
  end

  # A question with no options is answered as free text (a textarea).
  defp free_form?(question), do: (question["options"] || []) == []

  defp input_type(%{"multiSelect" => true}), do: "checkbox"
  defp input_type(_question), do: "radio"

  defp field_name(%{"multiSelect" => true}, i), do: "q_#{i}[]"
  defp field_name(_question, i), do: "q_#{i}"

  defp choice_class(%{"multiSelect" => true}), do: "checkbox checkbox-primary mt-0.5"
  defp choice_class(_question), do: "radio radio-primary mt-0.5"

  defp format_answer(a) when is_list(a), do: Enum.join(a, ", ")
  defp format_answer(a), do: to_string(a)

  # Right is whoever the reader is speaking as, which differs per surface.
  defp side(role, role), do: "chat-end"
  defp side(_role, _own), do: "chat-start"

  defp tone(role, role), do: "chat-bubble-primary"
  defp tone(_role, _own), do: "bg-base-200 text-base-content"
end
