defmodule CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion do
  @moduledoc """
  Ask the user a question with the answers written out for them.

  One to four questions, each with options they pick from and an "Other" box.
  Use it the moment a decision is theirs to make. Prefer it to `send_message`
  whenever the alternatives can be named — they get a tap instead of a
  paragraph, and naming them is most of the thinking.

  Returns as soon as the question is delivered. An agent we run should stop
  after asking: the answer arrives as a message.
  """

  # Why this exists at all
  #
  # Claude Code has `AskUserQuestion` natively and the plugin hook relays it to
  # `POST /api/questions/ask` — headers, options with descriptions, single or
  # multi select, an "Other" box. Nothing of ours could create one.
  # `send_message` hardcodes `"options" => []`, which the renderer reads as
  # free-form, so every question an Alloy agent asked came back as a paragraph
  # to interpret however closed the question actually was.
  #
  # Everything downstream was already built: `ChatComponents.question/1` renders
  # the options, `Notifications.collect_answers/2` resolves a list or a single
  # choice or the free-text other, and `answer_question_request/2` delivers the
  # result to the asking agent. The only missing piece was a way in.
  #
  # Why it does not block until the answer arrives
  #
  # Asked and settled 2026-09-06. `send_message` carries the original account of
  # the attempt — a synchronous wait whose transport gave up long before any
  # person answered, with every retry creating another question — and two things
  # about today's setup keep the answer the same.
  #
  # The wait is unbounded and no leg of the path is. The harness MCP client
  # defaults to thirty seconds; the one tool that waits on purpose,
  # `run_browser_script`, raises it to sixty and says both sides must agree or
  # "the first turns an answer into a timeout with no way to tell them apart". A
  # minute is the longest anything holds. And questions never expire — story 896
  # decided against a sweeper, because "a question vanishing on a clock is a
  # decision the user never made disappearing from the one place they would have
  # seen it" — so a blocking call would have to hold for as long as a question
  # can stay pending, which is forever.
  #
  # Beyond the plumbing: a blocked agent is indistinguishable from a wedged one,
  # a harness restart kills the call while the question row survives, and holding
  # the turn forfeits what the reply text promises — carry on with anything the
  # answer does not block.
  #
  # A short bounded wait was offered and declined: it buys a synchronous feel
  # when somebody happens to be watching, at the cost of a timeout two sides have
  # to agree on, for a path that already works.
  #
  # Why a separate tool rather than an option on `send_message`
  #
  # They are different acts. `send_message` opens a question; this one closes it
  # — the answer is constrained to a set the agent wrote, and choosing that set
  # is the work. As an optional field on a free-form tool it would be skipped,
  # the way optional structure usually is, and the caller would get a textarea
  # back for a question with three obvious answers.
  #
  # Keep this block as comments, not moduledoc. `Anubis.Server.Component`
  # advertises the moduledoc as the tool's `description`, so it is sent to every
  # agent at connect and `SpineTest` caps that payload at 20 KB. These notes cost
  # 3,199 bytes there and took the spine to 20,958 — the test caught it the same
  # afternoon they were written.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Notifications
  alias CodeMySpec.Sessions

  schema do
    # Terse on purpose. Every byte here is advertised to every Claude Code agent
    # at connect, and `SpineTest` holds that payload under 20 KB — the first
    # draft of this doc put it over on its own. The detail lives in the
    # moduledoc, which nothing pays for.
    field :questions, {:list, :map},
      required: true,
      doc:
        "1-4 objects: question (required), options (required, [{label, description}]), " <>
          "header, multiSelect."

    field :title, :string, doc: "Notification heading."
  end

  @max_questions 4

  @impl true
  def execute(%{questions: questions} = params, frame)
      when is_list(questions) and questions != [] do
    with :ok <- check_count(questions),
         {:ok, normalized} <- normalize(questions),
         {:ok, id} <- ask(frame, normalized, params[:title]) do
      {:reply, Response.tool() |> Response.text(asked(frame, id, normalized)), frame}
    else
      {:error, message} when is_binary(message) ->
        {:reply, Response.tool() |> Response.error(message), frame}

      {:error, reason} ->
        {:reply,
         Response.tool() |> Response.error("Could not reach the user: #{inspect(reason)}"), frame}
    end
  end

  def execute(_params, frame) do
    {:reply,
     Response.tool()
     |> Response.error("questions is required and must be a non-empty list"), frame}
  end

  # Four is Claude Code's own limit and the number a person will actually read
  # in one notification. Refused rather than truncated: silently dropping the
  # fifth question means an agent waits for an answer to something nobody was
  # shown.
  defp check_count(questions) when length(questions) <= @max_questions, do: :ok

  defp check_count(questions) do
    {:error,
     "#{length(questions)} questions is more than the #{@max_questions} a person is shown at " <>
       "once. Ask the ones that block you now; the rest can follow."}
  end

  # The renderer reads string keys, and a tool call may arrive with either. A
  # question that normalizes to no options is refused rather than quietly
  # rendering as a textarea — that is `send_message`, and an agent that meant to
  # offer choices should hear that it did not.
  defp normalize(questions) do
    Enum.reduce_while(questions, {:ok, []}, fn question, {:ok, acc} ->
      case normalize_one(question) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_one(question) do
    text = get(question, "question")
    options = question |> get("options") |> List.wrap() |> Enum.map(&normalize_option/1)

    cond do
      not is_binary(text) or text == "" ->
        {:error, "every question needs a `question`"}

      options == [] ->
        {:error,
         "\"#{String.slice(to_string(text), 0, 60)}\" has no options. Give it some, or call " <>
           "`send_message` for an open question."}

      true ->
        {:ok,
         %{
           "question" => text,
           "header" => get(question, "header"),
           "multiSelect" => get(question, "multiSelect") == true,
           "options" => options
         }}
    end
  end

  defp normalize_option(option) when is_map(option) do
    %{"label" => to_string(get(option, "label")), "description" => get(option, "description")}
  end

  defp normalize_option(label), do: %{"label" => to_string(label), "description" => nil}

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp get(_map, _key), do: nil

  defp ask(
         %{assigns: %{current_scope: %{user: %{id: user_id}} = scope}} = frame,
         questions,
         title
       ) do
    attrs = %{
      "questions" => questions,
      # The caller's title, which this read off `frame.assigns` — where it never
      # was. It arrives in the params, so every question the agents asked was
      # headed "Claude has a question" while the notification the agent wrote
      # said something useful like "Capital vassalization rule".
      "title" => title_or_default(title),
      # Who to hand the answer back to — off the connection, the same as
      # `send_message`. Nil for a Claude Code session, which polls.
      "agent_id" => frame.assigns[:agent_id],
      "session_external_id" => session_id_unless_agent(frame.assigns[:agent_id], scope)
    }

    case Notifications.create_question_request(user_id, attrs) do
      {:ok, request} -> {:ok, request.id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp ask(_frame, _questions, _title) do
    {:error, "No user on this scope, so there is nobody to ask. Ask in the terminal instead."}
  end

  defp title_or_default(title) when is_binary(title) and title != "", do: title
  defp title_or_default(_title), do: "Claude has a question"

  defp working_copy_id(%{active_working_copy_id: id}) when is_binary(id), do: id
  defp working_copy_id(_scope), do: nil

  defp asked(frame, id, questions) do
    """
    Asked #{length(questions)} question(s). Question id: #{id}

    #{waiting_advice(frame.assigns[:agent_id])}
    """
  end

  # Same split as `send_message`: an agent we run stops and is woken by the answer,
  # a Claude Code session keeps running and polls.
  defp waiting_advice(agent_id) when is_binary(agent_id) do
    "Stop now. Do not poll and do not wait — their answer will be delivered to " <>
      "you as a message. Anything the answer does not block, you can finish first."
  end

  defp waiting_advice(_agent_id) do
    "They will not answer instantly. Do other work, or stop — the stop hook will " <>
      "bring you back. Call `check_answer` with that id for the reply."
  end

  # A session or an agent, never both. `Sessions.external_id_for_harness/1`
  # answers nil for an agent's working copy anyway, so stamping it wrote
  # nothing — but naming both implied the two identities were interchangeable,
  # and a page reading the wrong one is what sent every agent question nowhere.
  defp session_id_unless_agent(agent_id, _scope) when is_binary(agent_id), do: nil

  defp session_id_unless_agent(_agent_id, scope),
    do: Sessions.external_id_for_harness(working_copy_id(scope))
end
