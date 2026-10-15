defmodule CodeMySpecWeb.ChatComponents do
  @moduledoc """
  One set of message components for every conversation surface.

  Used by the support inbox, the story interview and the agent conversation.

  **Which side is "mine"** is an argument (`own_role`): the operator sits right
  in the support inbox, the assistant in an agent conversation.

  **Calls and results.** A tool call is an assistant turn carrying a
  `tool_calls` array; a `role: :tool` message is a result
  (`Conversations.add_tool_result/5`), rendered inside the call it answers.
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
    <.notice id={@id} marker={@marker} inserted_at={@message.inserted_at}>
      {Message.text(@message)}
    </.notice>
    """
  end

  def turn(%{message: %{tool_calls: calls}} = assigns) when is_list(calls) and calls != [] do
    ~H"""
    <div id={@id} class="space-y-1">
      <.tool_call
        :for={call <- @message.tool_calls}
        id={"tool-call-#{@message.id}-#{call["id"]}"}
        name={call["name"]}
        args={call["arguments"] || %{}}
        call_id={call["id"]}
        agent_role={@message.agent_role}
        result={@results[call["id"]]}
        inserted_at={@message.inserted_at}
      />
    </div>
    """
  end

  # A result whose call is not on this page (paginated transcript). Rendered on
  # its own rather than dropped.
  def turn(%{message: %{role: :tool}} = assigns) do
    ~H"""
    <.tool_call
      id={@id}
      name={orphan_name(@message)}
      call_id={@message.tool_call_id}
      agent_role={@message.agent_role}
      result={@message}
      inserted_at={@message.inserted_at}
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

  def turn(assigns) do
    if routine_notice?(assigns.message), do: routine_notice(assigns), else: plain_turn(assigns)
  end

  def routine_notice?(%{role: :operator, sender_id: "promotion-notice"}), do: true

  # Older confirmations, and every landing, carry the sender human messages do.
  def routine_notice?(%{role: :operator} = message) do
    Regex.match?(
      ~r/\A(The (reload|restart) from your promotion is confirmed:|Your promotion of .* landed on main)/,
      Message.text(message)
    )
  end

  def routine_notice?(_message), do: false

  defp routine_notice(assigns) do
    ~H"""
    <details
      id={@id}
      data-test="routine-notice"
      class="rounded border border-base-300 px-3 py-1 text-xs"
    >
      <summary class="cursor-pointer">Promotion confirmed</summary>
      <div class="mt-2 whitespace-pre-wrap break-words">{Message.text(@message)}</div>
    </details>
    """
  end

  # The tool's name rides on `sender_id` as `"agent:<name>"` — see
  # `Conversations.add_tool_result/5`.
  defp orphan_name(%{sender_id: "agent:" <> name}) when name != "", do: name
  defp orphan_name(_message), do: "tool"

  @doc """
  When a turn landed, in the reader's own clock rather than the server's.

  Rendered server-side in UTC and corrected in the browser by the `LocalTime`
  hook. `phx-update="ignore"` so a later patch does not morph the text back to
  the UTC fallback.
  """
  attr :id, :string, required: true
  attr :at, :any, required: true, doc: "a DateTime"
  attr :class, :string, default: "shrink-0 opacity-50"

  def local_time(assigns) do
    ~H"""
    <time
      id={@id}
      phx-hook="LocalTime"
      phx-update="ignore"
      datetime={DateTime.to_iso8601(@at)}
      class={@class}
    >
      {Calendar.strftime(@at, "%b %-d, %H:%M")} UTC
    </time>
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
      inserted_at={@message.inserted_at}
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
  attr :inserted_at, :any, default: nil, doc: "a DateTime, when the turn carries one"

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
      <div
        :if={@label || @inserted_at}
        class="chat-header flex items-center gap-2 text-xs opacity-60"
      >
        <span :if={@label}>{@label}</span>
        <.local_time :if={@inserted_at} id={"#{@id}-time"} at={@inserted_at} />
      </div>
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
              unmarked lines. `max-w-none` because the bubble sets the width.

              No `prose-invert` — `.chat-prose` in app.css makes every prose
              color token `inherit` instead, from the bubble's own
              `chat-bubble-primary`/`text-base-content`, which already knows
              which text color is readable on itself per theme. A hardcoded
              invert-or-not here can only match one theme at a time; ask this
              once and it works in both.

              Prose only. Arguments and results are code and stay in <pre>. --%>
        <div
          :if={@text != ""}
          class="chat-prose prose prose-sm max-w-none prose-p:my-1 prose-ul:my-1 prose-ol:my-1 prose-pre:my-1"
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

  One collapsible per call, with its result inside it. The header carries a
  one-line summary of the call (`Bash — <description>`); everything else is
  behind the disclosure, so a turn that called five tools is five lines.
  """
  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :args, :map, default: %{}
  attr :call_id, :string, default: nil
  attr :agent_role, :string, default: nil
  attr :result, :any, default: nil, doc: "the %Message{} answering this call, if it has returned"
  attr :inserted_at, :any, default: nil, doc: "a DateTime, when the call carries one"

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
        <%!-- Keyed on `@id` rather than `call_id` — call ids are sequential
              per agent run (`call_0`, `call_1`, ...) and repeat across a long
              conversation, so two different calls sharing one landed as two
              `<time>` elements with the same id and LiveView refused to
              patch the page ("Duplicate id found"). `@id` is unique per
              rendered call: the loop site derives it from the message id
              plus the call id, and the orphan-result clause already passes
              its own turn id. --%>
        <.local_time
          :if={@inserted_at}
          id={"#{@id}-time"}
          at={@inserted_at}
          class="shrink-0 text-xs opacity-40"
        />
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

  # What this call did, in one line, from the argument that carries each tool's
  # point (Bash's `description`, a file tool's path, a search's pattern). Falls
  # back to nil, never a generic guess: "first string argument" picks a Write's
  # whole `content`.
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
  attr :inserted_at, :any, default: nil, doc: "a DateTime, when the notice carries one"
  slot :inner_block, required: true

  def notice(assigns) do
    ~H"""
    <div
      id={@id}
      data-test={@marker}
      class="flex items-start justify-between gap-2 rounded-box border border-warning/40 bg-warning/10 p-3 text-sm"
    >
      <div class="min-w-0">{render_slot(@inner_block)}</div>
      <.local_time
        :if={@inserted_at}
        id={"#{@id}-time"}
        at={@inserted_at}
        class="shrink-0 text-xs opacity-60"
      />
    </div>
    """
  end

  @doc """
  A question the agent asked, answerable where it is shown.

  Shared by `QuestionLive.Show` and the agent transcript. Answered questions
  keep rendering what was asked and what was said: the answer is part of the
  record.

  `on_submit` names the event, since hosts handle it differently. `target` is
  `phx-target` verbatim: nil for a LiveView, `@myself` inside a stateful
  `LiveComponent`.
  """
  attr :id, :string, default: nil
  attr :request, :any, required: true, doc: "a %Notifications.QuestionRequest{}"
  attr :on_submit, :string, default: "submit"
  attr :target, :any, default: nil

  def question(assigns) do
    ~H"""
    <div id={@id} data-test="question-request" data-status={@request.status} class="card bg-base-200">
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-chat-bubble-left-right" class="size-5 text-primary" />
          {@request.title || "A question for you"}
        </h2>

        <div :if={@request.status == "answered"} data-test="question-answered" class="mt-2">
          <div class="alert alert-success">
            <.icon name="hero-check-circle" class="size-5" /> Answer sent.
          </div>
          <p :if={main_agent_answered?(@request)} class="mt-2 text-sm opacity-70">
            {answered_by_agent(@request)} Correct it below if that's wrong.
          </p>
          <dl class="mt-4 space-y-2">
            <div :for={{q, a} <- @request.answers} class="text-sm">
              <dt class="font-semibold opacity-70">{q}</dt>
              <dd>{format_answer(a)}</dd>
            </div>
          </dl>
          <%!-- The answer this one replaced, kept in front of the person who
          replaced it. Criterion 3220: a main agent that reads the records
          wrongly is only diagnosable from the reading it gave, and this page
          is the one place it was ever shown. --%>
          <div
            :for={revision <- answer_history(@request)}
            data-test="answer-superseded"
            class="mt-4 border-l-2 border-base-300 pl-3 text-sm opacity-60"
          >
            <p class="font-semibold">Replaced {superseded_by(revision)} answer</p>
            <dl class="mt-1 space-y-1">
              <div :for={{q, a} <- revision_answers(revision)}>
                <dt class="opacity-70">{q}</dt>
                <dd>{format_answer(a)}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div :if={@request.status == "withdrawn"} data-test="question-withdrawn" class="mt-2">
          <div class="alert">
            <.icon name="hero-arrow-uturn-left" class="size-5" />
            Withdrawn by the agent that asked: {@request.withdrawn_reason}
          </div>
        </div>

        <form
          :if={@request.status == "pending" or main_agent_answered?(@request)}
          phx-submit={@on_submit}
          phx-target={@target}
          data-test="question-form"
          class="mt-2 space-y-6"
        >
          <%!-- Read, not required: a host with only ever one pending question
          (the standalone page, an agent's own conversation) answers `Enum.find`
          on its own single list and never looks at this. A host aggregating
          across several agents (the notification dropdown) cannot tell two
          forms apart without it. --%>
          <input type="hidden" name="request_id" value={@request.id} />
          <fieldset :for={{question, i} <- Enum.with_index(@request.questions)} class="space-y-2">
            <div>
              <span :if={question["header"]} class="badge badge-primary badge-sm">
                {question["header"]}
              </span>
              <p class="mt-1 font-medium">{question["question"]}</p>
              <%!-- What the agent actually asked, when the main agent put the
              question in the user's terms to escalate it (story 1060,
              criterion 3253).

              Kept, and not required to decide. A person who wants to know why
              is entitled to, and an escalation that discards the original
              leaves the answer unmoored from the thing it decides — but the
              decision has to be makeable without reading it, which is why this
              is a detail rather than the question. --%>
              <details :if={question["asked_as"]} class="mt-1">
                <summary class="cursor-pointer text-xs opacity-60">
                  What the agent asked
                </summary>
                <p data-test="question-asked-as" class="mt-1 text-xs opacity-70">
                  {question["asked_as"]}
                </p>
              </details>
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

  @doc """
  The flash for what `Notifications.answer_question_request/3` answered.

  Shared by every host of `question/1`, so a refused answer reads the same
  wherever it was given rather than as "Answer sent".
  """
  @spec answer_flash({:ok, term()} | {:error, term()}) :: {:info | :error, String.t()}
  def answer_flash({:ok, _request}), do: {:info, "Answer sent."}

  def answer_flash({:error, :empty_answer}),
    do: {:error, "Pick an option or type an answer first."}

  def answer_flash({:error, {:already_resolved, _status}}), do: {:info, "Already answered."}
  def answer_flash({:error, reason}), do: {:error, "The answer was not sent: #{inspect(reason)}"}

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

  # A main/product agent's answer is provisional until a person confirms or
  # corrects it. A user's own answer is final (`answer_question_request/3`
  # refuses a second), so no form is offered for it.
  defp main_agent_answered?(%{status: "answered", answered_by: by})
       when by in ~w(main_agent product_agent),
       do: true

  defp main_agent_answered?(_request), do: false

  defp answered_by_agent(%{answered_by: "product_agent"}),
    do: "The product agent answered this as the owner of the criteria."

  defp answered_by_agent(_request), do: "The main agent answered this from project records."

  # Nil on rows written before `answer_history` existed.
  defp answer_history(%{answer_history: revisions}) when is_list(revisions), do: revisions
  defp answer_history(_request), do: []

  defp revision_answers(revision), do: Map.get(revision, "answers") || %{}

  defp superseded_by(revision) do
    case Map.get(revision, "answered_by") do
      "main_agent" -> "the main agent's"
      "product_agent" -> "the product agent's"
      _user -> "an earlier"
    end
  end

  @doc """
  Fold a message list into the items a transcript renders.

  Runs of two or more consecutive calls fold into one expandable item; a lone
  call renders as itself. Back-to-back routine promotion notices fold too.
  `break_after` names message ids a run must split after (e.g. an unanswered
  question, so its form renders in order and visible).

  Returns `{items, results_by_call_id}`; items carry an `:id`, so the caller can
  stream them.
  """
  @spec group_turns([struct()], MapSet.t()) :: {[map()], %{String.t() => struct()}}
  def group_turns(messages, break_after \\ MapSet.new()) do
    results = results_by_call_id(messages)
    called = call_ids(messages)

    items =
      messages
      |> Enum.reject(&nested?(&1, called))
      |> Enum.chunk_by(&run_kind/1)
      |> Enum.flat_map(fn run ->
        cond do
          # Count calls, not messages: one turn can carry several calls.
          call?(hd(run)) and call_count(run) > 1 ->
            run |> split_after(break_after) |> Enum.flat_map(&fold/1)

          # A landing and its reload arrive back to back; fold them.
          routine_notice?(hd(run)) and length(run) > 1 ->
            [Map.put(group(run), :notices, true)]

          true ->
            singles(run)
        end
      end)

    {items, results}
  end

  defp run_kind(message) do
    cond do
      call?(message) -> :call
      routine_notice?(message) -> :notice
      true -> :turn
    end
  end

  # Splits a run after each message in `break_after`, so something (a pending
  # question's form) can render between calls instead of below later work or
  # hidden in an expander. The caller names the breaks: what deserves one is not
  # a fact about messages.
  # See knowledge/web, "Transcripts".
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

  # A piece of a split run folds on its own terms; one call renders as itself.
  defp fold(messages) do
    if call_count(messages) > 1, do: [group(messages)], else: singles(messages)
  end

  # Results keyed by the call they answer. Folded in order: a call clears any
  # result standing against its id, because call ids repeat across runs in one
  # conversation.
  # See knowledge/web, "Transcripts".
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

  # A result renders inside its call, so it is dropped from the top level only
  # when that call is on this page.
  defp nested?(%{role: :tool, tool_call_id: id}, called) when is_binary(id),
    do: MapSet.member?(called, id)

  defp nested?(_message, _called), do: false

  # `grouped` is carried, not inferred from length: a folded run is often one
  # message carrying several calls.
  defp singles(messages), do: Enum.map(messages, &%{id: &1.id, messages: [&1], grouped: false})
  defp group(run), do: %{id: hd(run).id, messages: run, grouped: true}

  # A call is an assistant turn carrying a `tool_calls` array.
  defp call?(%{tool_calls: calls}) when is_list(calls) and calls != [], do: true
  defp call?(_message), do: false

  @doc "One item from `group_turns/1` — a lone turn, or a run folded into a group."
  attr :id, :string, required: true
  attr :item, :any, required: true
  attr :own_role, :atom, default: :assistant
  attr :results, :map, default: %{}

  def turn_item(%{item: %{notices: true}} = assigns) do
    ~H"""
    <details
      id={@id}
      data-test="routine-notice-run"
      data-count={length(@item.messages)}
      class="rounded border border-base-300 px-3 py-1 text-xs"
    >
      <summary class="cursor-pointer">Promotion confirmed ×{length(@item.messages)}</summary>
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

  # Counts calls, not messages: a turn can carry more than one.
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
