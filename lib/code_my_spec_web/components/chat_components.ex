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
        name={call_text(call)}
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

  # The recorder writes a tool result as the *request* half of the next turn,
  # because that is where the model put it — an Anthropic turn carries results
  # as user-role content blocks. So `role: :user` means "what the model was
  # sent", which is a person's typing sometimes and a tool's output the rest of
  # the time, and the prefix is the only thing that says which.
  #
  # Taking the role at face value attributed 604 tool results to the operator
  # in this project alone: the largest category in the transcript, every one
  # shown as something a person typed.
  def turn(%{message: %{role: :user}} = assigns) do
    case Message.text(assigns.message) do
      "← failed: " <> rest -> tool_result_turn(assigns, rest, true)
      "← result: " <> rest -> tool_result_turn(assigns, rest, false)
      _ -> plain_turn(assigns)
    end
  end

  def turn(assigns), do: plain_turn(assigns)

  defp tool_result_turn(assigns, text, failed?) do
    assigns = assigns |> assign(:text, text) |> assign(:failed, failed?)

    ~H"""
    <.tool_result
      id={@id}
      call_id={@message.tool_call_id}
      agent_role={@message.agent_role}
      failed={@failed}
      text={@text}
    />
    """
  end

  defp plain_turn(assigns) do
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

  @doc """
  A call the agent made: which tool, and what it was given.

  The recorder stores these as `"<tool>\\n<json arguments>"` in one text field,
  and rendering that whole is how a `Write` of a source file became several
  thousand characters of escaped JSON with the turns either side pushed off the
  screen.

  The name is read every time and the arguments occasionally, so the name is
  always on screen and the arguments sit behind a disclosure. A payload past
  the limit is cut — and says it was cut, because a transcript that looks
  complete and is not is a record you cannot trust.
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :call_id, :string, default: nil
  attr :agent_role, :string, default: nil

  @args_limit 600

  def tool_call(assigns) do
    {tool, args} =
      case String.split(assigns.name, "\n", parts: 2) do
        [tool, args] -> {tool, String.trim(args)}
        [tool] -> {String.trim(tool), ""}
      end

    cut? = byte_size(args) > @args_limit

    assigns =
      assigns
      |> assign(:tool, tool)
      |> assign(:args, if(cut?, do: binary_part(args, 0, @args_limit) <> "…", else: args))
      |> assign(:cut, cut?)

    ~H"""
    <div
      id={@id}
      data-test="tool-call"
      data-tool={@tool}
      data-tool-call-id={@call_id}
      data-agent-role={@agent_role}
      data-truncated={to_string(@cut)}
      data-state="done"
      class="rounded-box border border-base-300 bg-base-200/60 p-3"
    >
      <div class="flex items-center gap-2">
        <.icon name="hero-wrench-screwdriver" class="size-4 shrink-0 opacity-60" />
        <span class="font-mono text-sm font-medium">{@tool}</span>
        <span :if={@agent_role} class="text-xs uppercase opacity-60">{@agent_role}</span>
      </div>

      <details :if={@args != ""} class="mt-2">
        <summary class="cursor-pointer text-xs opacity-60">arguments</summary>
        <pre class="mt-1 overflow-x-auto whitespace-pre-wrap break-all font-mono text-xs opacity-80">{@args}</pre>
        <p :if={@cut} class="mt-1 text-xs italic opacity-50">
          truncated — the transcript shows what was called, not the whole payload
        </p>
      </details>
    </div>
    """
  end

  @doc """
  What a call came back with.

  A failure is marked rather than left to the text. It is where a run starts
  going wrong, usually several turns before the agent says anything about it,
  and an operator scanning for that moment should not have to read every result
  to find the one that matters.
  """
  attr :id, :string, default: nil
  attr :call_id, :string, default: nil
  attr :agent_role, :string, default: nil
  attr :failed, :boolean, default: false
  attr :text, :string, required: true

  def tool_result(assigns) do
    ~H"""
    <div
      id={@id}
      data-test="tool-result"
      data-tool-call-id={@call_id}
      data-agent-role={@agent_role}
      data-failed={to_string(@failed)}
      class={[
        "rounded-box border p-3",
        @failed && "border-error/40 bg-error/10",
        !@failed && "border-base-300 bg-base-200/60"
      ]}
    >
      <div class="mb-1 flex items-center gap-2 text-xs opacity-60">
        <.icon
          name={if @failed, do: "hero-x-circle", else: "hero-arrow-uturn-left"}
          class="size-4 shrink-0"
        />
        <span>{if @failed, do: "failed", else: "result"}</span>
        <span :if={@agent_role} class="uppercase">{@agent_role}</span>
      </div>
      <pre class="overflow-x-auto whitespace-pre-wrap break-words font-mono text-xs">{@text}</pre>
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

  # The same string the recorder stores, built from the array shape instead.
  #
  # `tool_call/1` reads "<tool>\\n<arguments>", which is how the recorder writes
  # one. A call stored as a `tool_calls` entry holds those two parts in fields,
  # and passing only the name threw the arguments away — so the recorder's calls
  # showed what they were given and the chat's did not, from data that had it
  # either way. Two writers, one rendering, which is what the rule asks for.
  defp call_text(%{"name" => name} = call) do
    case call["arguments"] do
      args when is_map(args) and args != %{} -> name <> "\n" <> Jason.encode!(args, pretty: true)
      _ -> name
    end
  end

  defp call_text(call), do: inspect(call)

  # Right is whoever the reader is speaking as, which differs per surface.
  defp side(role, role), do: "chat-end"
  defp side(_role, _own), do: "chat-start"

  defp tone(role, role), do: "chat-bubble-primary"
  defp tone(_role, _own), do: "bg-base-200 text-base-content"
end
