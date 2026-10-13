defmodule CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion do
  @moduledoc """
  Ask the user a question with the answers written out for them.

  One to four questions with choices, or one free-text question with options: [].
  A linked task is blocked atomically; omitted task_id uses your active task.
  You may continue unrelated work. Collect answers with check_answer, then
  explicitly resume the blocked task after its blocker has been resolved.
  """

  # Creation returns immediately. The durable question outlives the turn;
  # answer delivery and explicit task resumption are separate operations.

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Main, as: MainAgent
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
    field :task_id, :string, doc: "Task to block; omitted defaults to your active task."
    field :session_id, :string, doc: "Injected by hook — do not set manually"

    field :about, :string,
      doc: "`criteria` for a story's acceptance criteria or spec: it goes to product."

    field :to, :string,
      doc:
        "`product` for criteria and spec, `main` for everything else (the default). " <>
          "Either answers, hands it to the other, or takes it to the user."
  end

  @max_questions 4

  @impl true
  def execute(%{questions: questions} = params, frame)
      when is_list(questions) and questions != [] do
    with :ok <- check_count(questions),
         {:ok, normalized} <- normalize(questions),
         {:ok, request} <-
           ask(frame, normalized, params, Map.get(params, :task_id, :active)) do
      {:reply, Response.tool() |> Response.text(asked(frame, request, normalized)), frame}
    else
      {:error, message} when is_binary(message) ->
        {:reply, Response.tool() |> Response.error(message), frame}

      {:error, reason} ->
        {:reply,
         Response.tool() |> Response.error("Could not reach the user: #{inspect(reason)}"), frame}
    end
  rescue
    exception ->
      {:reply, Response.tool() |> Response.error(crashed(exception, __STACKTRACE__)), frame}
  end

  def execute(_params, frame) do
    {:reply,
     Response.tool()
     |> Response.error("questions is required and must be a non-empty list"), frame}
  end

  # A crash here costs more than a crash in most tools, which is why this is
  # the one place that rescues rather than letting it propagate.
  #
  # `9f4eeb8f`: mid-QA on story 1005 this raised `internal_error: Tool
  # execution crashed`, which killed the agent process immediately after the
  # call. The rest of the turn went with it, the row was left claiming
  # `running` with `turn_started_at` still set, and the question the agent had
  # asked reached nobody until somebody restarted it by hand. A session lost
  # its only channel to the operator, in the act of using it.
  #
  # Two things follow from that and both are here. An agent asking for a
  # decision must end up either with the question delivered or with an answer
  # it can act on — the issue's own words are "succeeds or fails without
  # killing the process/losing the turn" — and this returns a refusal, which
  # `Alloy` hands back as an ordinary tool result rather than a dead loop.
  #
  # And the exception has to survive somewhere. A later investigation read this
  # whole call chain statically, found no candidate, and could not correlate
  # anything because the incident predated log retention and nothing had
  # recorded the real error. So the reason goes to the log with its stacktrace
  # and into the agent's own transcript: the next occurrence is diagnosable
  # rather than another unreproducible report.
  defp crashed(exception, stacktrace) do
    Logger.error(
      "[AskUserQuestion] crashed: #{Exception.message(exception)}\n" <>
        Exception.format_stacktrace(stacktrace)
    )

    """
    The question was not delivered: #{Exception.message(exception)}

    This is a fault in the tool rather than in what you asked, and it has been
    logged with its stacktrace. Report it with `create_issue` (scope
    `framework`) and carry on with anything the answer does not block — your
    turn is intact, which is the part that used to be lost here.
    """
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

  # The renderer accepts a single free-text question or a group of choices.
  defp normalize(questions) do
    Enum.reduce_while(questions, {:ok, []}, fn question, {:ok, acc} ->
      case normalize_one(question, length(questions) == 1) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_one(question, allow_free_text?) do
    text = get(question, "question")
    options = question |> get("options") |> List.wrap() |> Enum.map(&normalize_option/1)

    cond do
      not is_binary(text) or text == "" ->
        {:error, "every question needs a `question`"}

      options == [] and not allow_free_text? ->
        {:error, "Ask a free-text question on its own, or provide choices for each question."}

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
         params,
         task_ref
       ) do
    attrs = %{
      "questions" => questions,
      # The caller's title, which this read off `frame.assigns` — where it never
      # was. It arrives in the params, so every question the agents asked was
      # headed "Claude has a question" while the notification the agent wrote
      # said something useful like "Capital vassalization rule".
      "title" => title_or_default(params[:title]),
      # Authenticated identity controls answer delivery. External sessions
      # collect durable replies through bounded event-driven check_answer.
      "agent_id" => frame.assigns[:agent_id],
      # Who it waits on first. An agent's question goes to the project's main
      # agent, which is story 1052's routing; a Claude Code session's goes
      # straight to the person, because there is nobody above it to route to.
      # One the asker marks `about: "criteria"` goes to product (8c91d5bc).
      "holder" =>
        MainAgent.holder_for(scope, frame.assigns[:agent_id], params[:about], params[:to]),
      "session_external_id" => session_id_unless_agent(frame.assigns[:agent_id], scope)
    }

    with {:ok, request} <-
           create_question(scope, user_id, attrs, task_ref, Map.get(params, :session_id)) do
      # Delivered rather than discovered. Story 1059 wakes the main agent on a
      # cadence, so a question raised now would be seen eventually — at the cost
      # of the asking agent waiting out a window for somebody who was idle
      # throughout.
      :ok = MainAgent.question_raised(scope, request)
      {:ok, request}
    end
  end

  defp ask(_frame, _questions, _title, _task_ref) do
    {:error, "No user on this scope, so there is nobody to ask. Ask in the terminal instead."}
  end

  defp create_question(scope, _user_id, %{"agent_id" => id} = attrs, task_ref, _session_id)
       when is_binary(id) do
    Notifications.create_agent_question_request(scope, id, attrs, task_ref)
  end

  defp create_question(scope, user_id, attrs, task_ref, session_id),
    do: Notifications.create_session_question_request(scope, user_id, attrs, task_ref, session_id)

  defp title_or_default(title) when is_binary(title) and title != "", do: title
  defp title_or_default(_title), do: "A question for you"

  defp working_copy_id(%{active_working_copy_id: id}) when is_binary(id), do: id
  defp working_copy_id(_scope), do: nil

  defp asked(frame, request, questions) do
    """
    Asked #{length(questions)} question(s). Question id: #{request.id}

    #{question_context(frame)}

    #{waiting_advice(frame.assigns[:agent_id])}#{held_by(request.holder)}
    """
  end

  defp question_context(%{assigns: %{current_scope: scope}}) do
    user = Map.get(scope, :user) || %{}
    project = Map.get(scope, :active_project) || %{}
    "Project: #{Map.get(project, :name, "unknown")}. User: #{Map.get(user, :email, "unknown")}."
  end

  defp question_context(_frame), do: ""

  # Says when a question has reached a person.
  #
  # A question has no dismiss and no expiry — deliberately, and story 896 argues
  # it well: one vanishing on a clock is a decision the user never made. The cost
  # falls on anybody who asks one by accident, and it has fallen twice. A QA
  # agent exercising the ask→answer round trip called this from a worktree of the
  # real project, so its typed tool was bound to the real dev harness, and two
  # "please ignore" probes became clutter in the owner's inbox (`08d4d7bd`).
  # Only the asker can take one back, with `withdraw_question` (8c91d5bc).
  #
  # Only when the holder is the person. An agent's question routed to the main
  # agent is ordinary traffic, and saying this every time would make the sentence
  # worth ignoring.
  defp held_by("user") do
    "\n\nThis one is waiting on a person, in their real inbox. If it goes moot, take " <>
      "it back with `withdraw_question` and the reason. If you meant to exercise the " <>
      "ask path rather than actually ask, withdraw it now and use a sandbox project's " <>
      "harness over HTTP instead."
  end

  defp held_by("product_agent"),
    do: "\n\nIt went to the product agent, which owns the story's criteria and spec."

  defp held_by(_main_agent), do: ""

  # Answer content is queued independently of the linked task's disposition.
  defp waiting_advice(agent_id) when is_binary(agent_id) do
    "The linked task is blocked, if any. Continue unrelated work; use check_answer " <>
      "to collect the reply and start_task to deliberately resume eligible work."
  end

  defp waiting_advice(_agent_id) do
    "The linked task is blocked, if any. They will not answer instantly — continue " <>
      "unrelated work, or stop and the stop hook will bring you back to it. Call " <>
      "`check_answer` with that id for the reply, and `start_task` to deliberately " <>
      "resume eligible work."
  end

  # A session or an agent, never both. `Sessions.external_id_for_harness/1`
  # answers nil for an agent's working copy anyway, so stamping it wrote
  # nothing — but naming both implied the two identities were interchangeable,
  # and a page reading the wrong one is what sent every agent question nowhere.
  defp session_id_unless_agent(agent_id, _scope) when is_binary(agent_id), do: nil

  defp session_id_unless_agent(_agent_id, scope),
    do: Sessions.external_id_for_harness(working_copy_id(scope))
end
