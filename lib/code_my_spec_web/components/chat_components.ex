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

  # What the orchestrator did, in the same stream as what the agent did.
  #
  # Before this clause the transcript recorded only the agent's own turns, so a
  # conversation that changed direction between one turn and the next carried no
  # explanation — the reason lived in a log on another machine. Story 985.
  #
  # Deliberately not a `tool_call`. The agent did not call this, and drawing it
  # as a call would say it did: a reader would take the stop as the agent's own
  # judgement rather than as something done to it.
  #
  # The count and the tool name are the rule John settled: say what happened,
  # how much of it there is, and which tool answers for the rest. A tool name
  # rather than a link, because half the readers of an agent's transcript are
  # agents and an agent cannot follow a link.
  def turn(%{message: %{role: :orchestrator}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-test="orchestrator-action"
      data-role="orchestrator"
      data-action-kind={orchestrator_kind(@message)}
      class="flex items-start gap-2 rounded-box border border-info/30 bg-info/5 px-3 py-2 text-sm"
    >
      <.icon name="hero-adjustments-horizontal" class="size-4 shrink-0 opacity-60" />

      <div class="min-w-0">
        <span>{Message.text(@message)}</span>

        <span
          :if={orchestrator_count(@message)}
          data-test="orchestrator-action-count"
          class="ml-1 font-medium"
        >
          {orchestrator_count(@message)}
        </span>

        <span
          :if={orchestrator_tool(@message)}
          data-test="orchestrator-action-tool"
          class="ml-1 opacity-70"
        >
          — {tool_lead(@message)} <code>{orchestrator_tool(@message)}</code>{tool_tail(@message)}
        </span>
      </div>
    </div>
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

  # Past this, a message is shown as a preview you can open.
  #
  # Nothing in a transcript bounded the length of a *message*, because the
  # collapsing that exists is for tool blocks and these are prose. Measured on
  # the live transcript: a 67 kB bubble beginning "Called the Read tool with the
  # following input", which is a sub-agent's work narrated back to its parent as
  # text rather than as `tool_use` blocks; and file-modified reminders at 24-48
  # kB that carry whole files.
  #
  # 1,500 characters is roughly a screen on a phone — past that you are
  # scrolling through one turn to reach the next.
  @preview_limit 1_500

  def chat_message(assigns) do
    long? = byte_size(assigns.text) > @preview_limit

    assigns =
      assigns
      |> assign(:long, long?)
      |> assign(:preview, if(long?, do: preview_of(assigns.text), else: assigns.text))

    ~H"""
    <div
      id={@id}
      data-test="message"
      data-role={@role}
      data-agent-role={@label}
      data-sender-id={@sender_id}
      data-long={to_string(@long)}
      class={["chat", side(@role, @own_role)]}
    >
      <div :if={@label} class="chat-header text-xs opacity-60">{@label}</div>
      <%!-- min-w-0 so the bubble may shrink below its content: without it a
            flex/grid ancestor sizes to the longest unbroken token, and the
            wrapping rules never get the chance to apply. --%>
      <div class={["chat-bubble min-w-0 break-words", tone(@role, @own_role)]}>
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
          :if={@text != "" and not @long}
          class={[
            "chat-prose prose prose-sm max-w-none prose-p:my-1 prose-ul:my-1 prose-ol:my-1 prose-pre:my-1",
            side(@role, @own_role) == "chat-end" && "prose-invert"
          ]}
        >
          {md_html(@text)}
        </div>

        <%!-- The whole message is kept — the model received it, so it is part of
              the record — but it opens rather than arriving unfolded. The
              preview renders as plain text, not markdown: a cut at 1,500 bytes
              lands mid-fence often enough that parsing it produces a code block
              swallowing the rest of the preview. --%>
        <details :if={@long} data-test="long-message" class="group">
          <summary class="cursor-pointer">
            <span class="whitespace-pre-wrap opacity-90">{@preview}</span>
            <span class="mt-1 block text-xs underline opacity-60">
              show all {byte_size(@text)} characters
            </span>
          </summary>
          <div class={[
            "chat-prose prose prose-sm mt-2 max-w-none border-t border-current/20 pt-2 prose-p:my-1",
            side(@role, @own_role) == "chat-end" && "prose-invert"
          ]}>
            {md_html(@text)}
          </div>
        </details>
        {render_slot(@extra)}
      </div>
    </div>
    """
  end

  # Cut on a line boundary where there is one nearby, so the preview does not
  # end mid-word.
  defp preview_of(text) do
    head = binary_part(text, 0, @preview_limit)

    case String.split(head, "\n") do
      [_] -> head <> "…"
      parts -> parts |> Enum.drop(-1) |> Enum.join("\n") |> Kernel.<>("\n…")
    end
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
    <%!-- `data-state`, not a boolean `data-answered`: a call renders as soon as
          the model makes it and is filled in when the result arrives, so what a
          reader needs is which of those it is looking at. `running` / `done` is
          the convention the rest of the app already uses (`preview_components`,
          `provisioning_live`), and `data-answered` had no consumer anywhere
          outside this component. --%>
    <details
      id={@id}
      data-test="tool-call"
      data-tool={@name}
      data-tool-call-id={@call_id}
      data-agent-role={@agent_role}
      data-truncated={to_string(@cut)}
      data-failed={to_string(@failed)}
      data-state={if @result, do: "done", else: "running"}
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

        <div
          :if={@result}
          data-test="tool-result"
          data-tool-call-id={@call_id}
          data-failed={to_string(@failed)}
        >
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

        <form
          :if={@request.status == "pending"}
          phx-submit={@on_submit}
          data-test="question-form"
          class="mt-2 space-y-6"
        >
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
  @spec group_turns([struct()], MapSet.t()) :: {[map()], %{String.t() => struct()}}
  def group_turns(messages, break_after \\ MapSet.new()) do
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
        if call?(hd(run)) and call_count(run) > 1 do
          run |> split_after(break_after) |> Enum.flat_map(&fold/1)
        else
          singles(run)
        end
      end)

    {items, results}
  end

  # Where a run must not be folded across.
  #
  # The fold collapses a run of calls into one expandable item, which is right
  # until something has to render *between* two of them. A pending question is
  # the case: three calls, then `ask_user_question`, then two more calls is one
  # item, and a form rendered after it appears below work that happened after
  # the question was asked. Putting it inside the item is worse — a question
  # nobody can see behind an expander is a question that does not get answered.
  #
  # So the caller names the messages a run has to break after, and the run
  # becomes several items with the boundary between them. Everything without a
  # boundary folds exactly as before.
  #
  # The caller names them rather than this looking them up, because what
  # deserves a break is not a fact about messages — today it is an unanswered
  # question, and the next one will be something else.
  defp split_after(run, break_after) do
    if MapSet.size(break_after) == 0 do
      [run]
    else
      run
      |> Enum.chunk_while(
        [],
        &chunk_on_break(&1, &2, break_after),
        fn
          [] -> {:cont, []}
          acc -> {:cont, Enum.reverse(acc), []}
        end
      )
      |> Enum.reject(&(&1 == []))
    end
  end

  defp chunk_on_break(message, acc, break_after) do
    acc = [message | acc]

    if MapSet.member?(break_after, message.id),
      do: {:cont, Enum.reverse(acc), []},
      else: {:cont, acc}
  end

  # A piece of a split run folds on its own terms: two calls still collapse, one
  # left over renders as itself rather than as a group of one.
  defp fold(messages) do
    if call_count(messages) > 1, do: [group(messages)], else: singles(messages)
  end

  # Carried on the message's own parts rather than in the sentence, so the view
  # can render them distinctly and a test can assert them without parsing prose.
  defp orchestrator_count(%{content: parts}) when is_list(parts) do
    Enum.find_value(parts, fn
      %{"type" => "count", "text" => text} -> text
      _ -> nil
    end)
  end

  defp orchestrator_count(_message), do: nil

  defp orchestrator_tool(%{content: parts}) when is_list(parts) do
    Enum.find_value(parts, fn
      %{"type" => "tool", "text" => text} -> text
      _ -> nil
    end)
  end

  defp orchestrator_tool(_message), do: nil

  # Which kind of act this was. "One decision is one action" is a claim about
  # decisions, and a stop that also nudges an agent about open work produces two
  # actions that are not duplicates of each other.
  defp orchestrator_kind(%{content: parts}) when is_list(parts) do
    Enum.find_value(parts, fn
      %{"type" => "kind", "text" => text} -> text
      _ -> nil
    end)
  end

  defp orchestrator_kind(_message), do: nil

  # A decision points at where the rest of it is; a nudge names the act to
  # perform. One template said "run X for the detail" for both, which told an
  # agent its own next call was somewhere to go reading (QA 985).
  defp tool_lead(message), do: if(orchestrator_kind(message) == "nudge", do: "call", else: "run")

  defp tool_tail(message),
    do: if(orchestrator_kind(message) == "nudge", do: "", else: " for the detail")

  # Results keyed by the call they answer, so a call can render its own.
  # A result belongs to the call it answered, not to every call that ever
  # carried its id.
  #
  # Tool call ids are sequential per agent run — `call_1`, `call_16`,
  # `call_26_retry` — so a conversation that has run all day holds `call_16`
  # several times over. Collecting them into a map keyed by id alone made the
  # newest call inherit the oldest surviving answer.
  #
  # What that looked like: an `ask_user_question` that had worked — question
  # created, delivered, answered — rendered with "No session_id available" from
  # a `start_task` eight hours earlier that happened to be call_16 too. The
  # error was real, belonged to a different call, and read as this one failing.
  # It only appeared once scrolling loaded the older turns, which is why it
  # showed up long after the call itself.
  #
  # Folded in order rather than comprehended: a call *clears* any result
  # standing against its id, so a later call starts unanswered and renders "no
  # result recorded" until its own answer arrives. Inheriting a stale one is
  # strictly worse than admitting there is none.
  defp results_by_call_id(messages) do
    Enum.reduce(messages, %{}, fn message, results ->
      results
      |> forget_answered_calls(message)
      |> record_result(message)
    end)
  end

  defp forget_answered_calls(results, %{tool_calls: calls}) when is_list(calls) do
    Enum.reduce(calls, results, fn call, acc ->
      case call["id"] do
        id when is_binary(id) -> Map.delete(acc, id)
        _ -> acc
      end
    end)
  end

  defp forget_answered_calls(results, _message), do: results

  defp record_result(results, %{role: :tool, tool_call_id: id} = message) when is_binary(id),
    do: Map.put(results, id, message)

  defp record_result(results, _message), do: results

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
