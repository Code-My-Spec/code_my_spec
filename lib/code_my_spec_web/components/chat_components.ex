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
  import CodeMySpecWeb.Markdown, only: [md_html: 1]

  alias CodeMySpec.Conversations.Message

  @doc """
  One turn, dispatched on what the message actually carries.

  Order matters: a halted or failed turn is a notice before it is a message,
  and a turn with calls is those calls rather than an empty bubble.
  """
  attr :id, :string, required: true
  attr :message, :any, required: true
  attr :own_role, :atom, default: :assistant, doc: "the role rendered on the right"
  attr :results, :map, default: %{}, doc: "results by tool_call_id, to render inside their call"

  def turn(%{message: %{agent_role: role}} = assigns) when role in ["halted", "failed"] do
    assigns = assign(assigns, :marker, "chat-#{role}")

    ~H"""
    <.notice id={@id} marker={@marker}>{Message.text(@message)}</.notice>
    """
  end

  def turn(%{message: %{tool_calls: calls}} = assigns) when is_list(calls) and calls != [] do
    ~H"""
    <div id={@id} class="space-y-1">
      <.tool_call
        :for={call <- @message.tool_calls}
        name={call["name"]}
        args={call["arguments"] || %{}}
        call_id={call["id"]}
        agent_role={@message.agent_role}
        result={@results[call["id"]]}
      />
    </div>
    """
  end

  # A result whose call is not on this page — the transcript is paginated, so a
  # call can be above the window while its answer is inside it. Rendered on its
  # own rather than dropped, because a result with nowhere to nest is still
  # something that happened.
  def turn(%{message: %{role: :tool}} = assigns) do
    ~H"""
    <.tool_call
      id={@id}
      name={orphan_name(@message)}
      call_id={@message.tool_call_id}
      agent_role={@message.agent_role}
      result={@message}
    />
    """
  end

  # Nothing to show — no text, no calls. Hidden rather than rendered as an
  # empty bubble, and still rendered as an element so the stream has its id.
  def turn(%{message: %{content: [], tool_calls: nil}} = assigns) do
    ~H"""
    <div id={@id} class="hidden"></div>
    """
  end

  def turn(assigns), do: plain_turn(assigns)

  # The tool's name rides on `sender_id` as `"agent:<name>"` — see
  # `Conversations.add_tool_result/5`.
  defp orphan_name(%{sender_id: "agent:" <> name}) when name != "", do: name
  defp orphan_name(_message), do: "tool"

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
        <%!-- The model writes markdown and always has; rendering it as plain
              text showed backticks, hyphens and hashes as literal characters.
              `md_html/1` is Earmark configured to escape raw HTML — checked,
              because this is model output rather than the authored content its
              moduledoc scopes it to — so a `<script>` in a reply renders as
              text rather than running.

              `prose` is the typography plugin, already loaded in app.css.
              Without it Tailwind's reset leaves `<ul>` at `list-style: none`
              and no indent, so a list parses correctly and renders as
              unmarked lines. `max-w-none` because the bubble sets the width,
              and `prose-invert` inside a filled bubble.

              Prose only. Arguments and results are code and stay in <pre>. --%>
        <div
          :if={@text != ""}
          class={[
            "chat-prose prose prose-sm max-w-none prose-p:my-1 prose-ul:my-1 prose-ol:my-1 prose-pre:my-1",
            side(@role, @own_role) == "chat-end" && "prose-invert"
          ]}
        >
          {md_html(@text)}
        </div>
        {render_slot(@extra)}
      </div>
    </div>
    """
  end

  @doc """
  A call the agent made, and what it came back with.

  One collapsible per call, which is the shape every chat UI that renders agent
  work converges on — `vercel/ai-chatbot`'s `ai-elements/tool.tsx` and
  `assistant-ui`'s opencode example both do exactly this. The result belongs
  *inside* the call. Rendered as a sibling card it doubles the block count and
  loses which call it answers, which is what this used to do.

  The summary on the header is what makes a run readable. `Bash` alone says
  nothing; `Bash — Check the alias group around line 69` says what happened, and
  the model already sends that text. Everything below the header is behind the
  disclosure, so a turn that called five tools is five lines.
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :args, :map, default: %{}
  attr :call_id, :string, default: nil
  attr :agent_role, :string, default: nil
  attr :result, :any, default: nil, doc: "the %Message{} answering this call, if it has returned"

  @args_limit 2_000

  def tool_call(assigns) do
    json = encode_args(assigns.args)
    cut? = byte_size(json) > @args_limit

    assigns =
      assigns
      |> assign(:summary, call_summary(assigns.name, assigns.args))
      |> assign(:json, if(cut?, do: binary_part(json, 0, @args_limit) <> "…", else: json))
      |> assign(:cut, cut?)
      |> assign(:failed, assigns.result != nil and assigns.result.tool_failed == true)

    ~H"""
    <details
      id={@id}
      data-test="tool-call"
      data-tool={@name}
      data-tool-call-id={@call_id}
      data-agent-role={@agent_role}
      data-truncated={to_string(@cut)}
      data-failed={to_string(@failed)}
      data-answered={to_string(@result != nil)}
      class={[
        "group rounded-box border",
        @failed && "border-error/40 bg-error/5",
        !@failed && "border-base-300 bg-base-200/40"
      ]}
    >
      <%!-- min-w-0 + break-all: `mcp__plugin_codemyspec_local__add_scenario` is
            one unbreakable token wider than a phone, and a flex item will not
            shrink below its content unless told to. --%>
      <summary class="flex cursor-pointer items-center gap-2 p-2 text-sm">
        <.icon
          name={if @failed, do: "hero-x-circle", else: "hero-wrench-screwdriver"}
          class={"size-4 shrink-0 #{if @failed, do: "text-error", else: "opacity-50"}"}
        />
        <span class="min-w-0 break-all font-mono font-medium">{@name}</span>
        <span :if={@summary} class="min-w-0 flex-1 truncate opacity-60">{@summary}</span>
        <span :if={@agent_role} class="shrink-0 text-xs uppercase opacity-40">{@agent_role}</span>
      </summary>

      <div class="space-y-3 border-t border-base-300 px-3 pb-3 pt-2">
        <div :if={@json != "{}"}>
          <h4 class="mb-1 text-xs uppercase tracking-wide opacity-50">Parameters</h4>
          <pre class="overflow-x-hidden whitespace-pre-wrap break-all rounded-box bg-base-300/40 p-2 font-mono text-xs opacity-80">{@json}</pre>
          <p :if={@cut} class="mt-1 text-xs italic opacity-50">
            truncated — the transcript shows what was called, not the whole payload
          </p>
        </div>

        <div :if={@result} data-test="tool-result" data-failed={to_string(@failed)}>
          <h4 class="mb-1 text-xs uppercase tracking-wide opacity-50">
            {if @failed, do: "Error", else: "Result"}
          </h4>
          <pre class={[
            "overflow-x-hidden whitespace-pre-wrap break-all rounded-box p-2 font-mono text-xs",
            @failed && "bg-error/10 text-error",
            !@failed && "bg-base-300/40 opacity-80"
          ]}>{Message.text(@result)}</pre>
        </div>

        <%!-- A call with no result yet is a call still running, or one whose
              answer never came back. Saying so beats an empty panel that reads
              as a rendering bug. --%>
        <p :if={is_nil(@result)} class="text-xs italic opacity-50">
          no result recorded for this call
        </p>
      </div>
    </details>
    """
  end

  defp encode_args(args) when is_map(args) do
    case Jason.encode(args, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(args)
    end
  end

  defp encode_args(other), do: inspect(other)

  # What this call actually did, in one line.
  #
  # Every tool has an argument that carries the point, and it is never the same
  # one. `Bash` sends a human-written `description` — present on 775 of 799
  # calls in this project's history — which is better than anything derivable
  # from the command. A file tool's point is the file. A search's is the
  # pattern. Guessing generically ("first string argument") picks `content` for
  # a `Write`, which is the whole file.
  #
  # Falls back to nothing rather than to something wrong: a header showing just
  # the tool name is honest, and the arguments are one click away.
  @summary_limit 80

  defp call_summary(_name, args) when not is_map(args), do: nil

  defp call_summary(name, args) do
    args
    |> summary_value(name)
    |> case do
      value when is_binary(value) and value != "" -> shorten(value)
      _ -> nil
    end
  end

  defp summary_value(%{"description" => d}, _name) when is_binary(d) and d != "", do: d
  defp summary_value(%{"file_path" => p}, _name) when is_binary(p), do: Path.basename(p)
  defp summary_value(%{"path" => p}, _name) when is_binary(p), do: Path.basename(p)
  defp summary_value(%{"url" => u}, _name), do: u
  defp summary_value(%{"pattern" => p}, _name), do: p
  defp summary_value(%{"title" => t}, _name), do: t
  defp summary_value(%{"statement" => s}, _name), do: s
  defp summary_value(%{"query" => q}, _name), do: q
  defp summary_value(%{"command" => c}, _name), do: c
  defp summary_value(%{"expression" => e}, _name), do: e
  defp summary_value(%{"selector" => s}, _name), do: s
  defp summary_value(%{"module_name" => m}, _name), do: m
  defp summary_value(_args, _name), do: nil

  defp shorten(text) do
    flat = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(flat) > @summary_limit do
      String.slice(flat, 0, @summary_limit - 1) <> "…"
    else
      flat
    end
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

        <%!-- Neither answered nor pending: the run stopped waiting. Without a
              branch here the card rendered its title and an empty body, which
              reads as a broken page rather than as a question that timed out —
              the same dead end as dropping it from the inbox, moved one click
              later. The question is still shown, because what was asked is the
              point of keeping the record at all. --%>
        <div
          :if={@request.status not in ["answered", "pending"]}
          data-test="question-closed"
          class="mt-2"
        >
          <div class="alert alert-warning">
            <.icon name="hero-clock" class="size-5" />
            <span>
              This question {@request.status} — the run stopped waiting, so it can no longer be answered.
            </span>
          </div>
          <dl class="mt-4 space-y-2">
            <div :for={question <- @request.questions} class="text-sm">
              <dt class="font-semibold opacity-70">{question["question"]}</dt>
            </div>
          </dl>
        </div>

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
  @doc """
  Fold a message list into the items a transcript renders.

  A turn that calls five tools writes five messages, and five blocks in a column
  is most of a phone screen spent on one turn. What the reader needs first is
  that five calls happened; which five is the follow-up.

  Only runs of two or more consecutive calls fold. Most calls are alone — 848 of
  them against 20 runs on this project — so wrapping every call in a group of
  one would make the common case worse to save the rare one.

  Returns items carrying an `:id`, so the caller can stream them.
  """
  @spec group_turns([struct()]) :: {[map()], %{String.t() => struct()}}
  def group_turns(messages) do
    results = results_by_call_id(messages)
    called = call_ids(messages)

    items =
      messages
      |> Enum.reject(&nested?(&1, called))
      |> Enum.chunk_by(&call?/1)
      |> Enum.flat_map(fn run ->
        # Calls, not messages. A turn can make three calls at once — the model
        # answers with three `tool_use` blocks in one response — and chunking by
        # message saw that as a single item and left it unfolded, which is the
        # exact case the fold exists for.
        if call?(hd(run)) and call_count(run) > 1, do: [group(run)], else: singles(run)
      end)

    {items, results}
  end

  # Results keyed by the call they answer, so a call can render its own.
  defp results_by_call_id(messages) do
    for %{role: :tool, tool_call_id: id} = message <- messages,
        is_binary(id),
        into: %{},
        do: {id, message}
  end

  # The ids of calls actually on this page.
  defp call_ids(messages) do
    for %{tool_calls: calls} <- messages,
        is_list(calls),
        call <- calls,
        is_binary(call["id"]),
        into: MapSet.new(),
        do: call["id"]
  end

  # A result renders inside its call, so it must not render again at the top
  # level — but only when that call is on the page. The transcript is
  # paginated, so a call can sit above the window while its answer is inside
  # it; that result stays, because it is still something that happened.
  defp nested?(%{role: :tool, tool_call_id: id}, called) when is_binary(id),
    do: MapSet.member?(called, id)

  defp nested?(_message, _called), do: false

  # `grouped` is carried rather than inferred from the list length. A turn can
  # make three calls in one message, so a folded run is often a single message
  # — and matching on `[message]` sent exactly that case to the unfolded clause.
  defp singles(messages), do: Enum.map(messages, &%{id: &1.id, messages: [&1], grouped: false})
  defp group(run), do: %{id: hd(run).id, messages: run, grouped: true}

  # Both writers now record a call the same way — an assistant turn carrying a
  # `tool_calls` array. The old check also had to sniff `role: :tool` text for
  # "a name is one token", because the recorder wrote calls that way; it does
  # not any more.
  defp call?(%{tool_calls: calls}) when is_list(calls) and calls != [], do: true
  defp call?(_message), do: false

  @doc "One item from `group_turns/1` — a lone turn, or a run folded into a group."
  attr :id, :string, required: true
  attr :item, :any, required: true
  attr :own_role, :atom, default: :assistant
  attr :results, :map, default: %{}

  def turn_item(%{item: %{grouped: false, messages: [message]}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <.turn id={@id} message={@message} own_role={@own_role} results={@results} />
    """
  end

  def turn_item(assigns) do
    ~H"""
    <details
      id={@id}
      data-test="tool-call-group"
      data-count={call_count(@item.messages)}
      class="rounded-box border border-base-300 bg-base-200/40 p-2"
    >
      <summary class="flex cursor-pointer items-center gap-2 text-sm">
        <.icon name="hero-wrench-screwdriver" class="size-4 shrink-0 opacity-50" />
        <span>used {call_count(@item.messages)} tools</span>
      </summary>

      <%!-- Each entry is one line, not a card. That is the point of folding: a
            group that expands into five cards has moved the problem rather
            than solved it. --%>
      <div class="mt-2 space-y-1">
        <.turn
          :for={message <- @item.messages}
          id={"#{@id}-#{message.id}"}
          message={message}
          own_role={@own_role}
          results={@results}
        />
      </div>
    </details>
    """
  end

  # A turn can carry more than one call, so the count is calls rather than
  # messages — "used 5 tools" above four rows would be a lie either way round.
  defp call_count(messages) do
    Enum.reduce(messages, 0, fn
      %{tool_calls: calls}, acc when is_list(calls) -> acc + length(calls)
      _message, acc -> acc + 1
    end)
  end

  # Right is whoever the reader is speaking as, which differs per surface.
  defp side(role, role), do: "chat-end"
  defp side(_role, _own), do: "chat-start"

  defp tone(role, role), do: "chat-bubble-primary"
  defp tone(_role, _own), do: "bg-base-200 text-base-content"
end
