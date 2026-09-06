defmodule CodeMySpec.McpServers.Tasks.Tools.SendMessage do
  @moduledoc """
  Send the user a message and get prose back.

  Was `ask_user`, and the name was doing damage. It sat beside no structured
  counterpart of ours, so it read as *the* way to reach a person and got used
  for questions that had three obvious answers — which came back as a textarea
  and a paragraph to interpret. `ask_user_question` is that counterpart now, and
  this is what is left when the answer genuinely is prose: "what should this copy
  say?", "how do you want this edge case handled?", or a check-in where
  enumerating choices would be artificial.

  Its notification has always been titled "Claude has a message", which is what
  it is.

  Pushes to the user's phone (Web Push → `QuestionLive.Show`, or the agent's own
  conversation) and renders a free-text box, because a question with no options
  is free-form by definition.

  ## Why this does not block

  It used to wait inline for the reply, up to ten minutes. That could never
  work: a tool call is dispatched through a `GenServer.call` whose timeout is
  measured in seconds, so the transport gave up long before any person could
  answer and the agent saw `-32603 Internal error`. Each attempt still created
  the question, so a user watching their queue saw the same thing asked over and
  over while the agent was told the tool was broken.

  Waiting minutes inside a synchronous call was the mistake, not the timeout
  value. A person is not a slow function; they are an event that arrives later.
  So this returns a question id rather than a reply. A Claude Code session
  fetches it with `check_answer` when it next looks; an agent of ours is sent
  the answer as a message and is allowed to stop in the meantime, which is why
  its stop is not refused while a question of its own is outstanding.

  ## Why this no longer goes over HTTP

  It used to hand off to `QuestionClient`, which POSTed to
  `/api/questions/ask` on the configured server. That made sense when the MCP
  server ran in the CLI and the rows lived in the cloud. It does not now: this
  runs *in* the cloud app, in the same process as `Notifications` and against
  the same database, so the request left the VM and came back to call the
  function that was already in scope.

  The cost was not only a round trip. It made the agent's own asking surface
  undrivable from a spex — in-process it answers `{:http, 401}`, because there
  is no server to authenticate to — so nothing has ever tested it. That is
  story 896's `given_`, and John's instruction: "stop arbitraging Claude's ask
  user question and implement our own mcp tool."

  `QuestionClient` stays for the CLI, which genuinely is a different process.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Notifications
  alias CodeMySpec.Sessions

  schema do
    field :message, :string,
      required: true,
      doc: "The free-form question/message to send the user. They reply in prose."
  end

  @impl true
  def execute(%{message: message}, frame) when is_binary(message) and message != "" do
    scope = frame.assigns[:current_scope]

    case ask(scope, message, frame.assigns[:agent_id]) do
      {:ok, id} ->
        {:reply,
         Response.tool()
         |> Response.text("""
         Asked #{recipient(scope)}. They have been notified.

         Question id: #{id}

         #{waiting_advice(frame.assigns[:agent_id])}
         """), frame}

      {:error, :no_user} ->
        {:reply,
         Response.tool()
         |> Response.error(
           "No user on this scope, so there is nobody to ask. Ask in the terminal instead."
         ), frame}

      {:error, reason} ->
        {:reply,
         Response.tool() |> Response.error("Could not reach the user: #{inspect(reason)}"), frame}
    end
  end

  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.error("message is required"), frame}
  end

  # Two callers, two different right answers.
  #
  # An agent we run can stop and be woken: the answer is dispatched to it as a
  # message, so telling it to poll would have it spend a turn per check on
  # somebody who has not started typing. A Claude Code session has no such
  # delivery and keeps running anyway, so `check_answer` remains its route.
  defp waiting_advice(agent_id) when is_binary(agent_id) do
    """
    Stop now. Do not poll and do not wait — their answer will be delivered to
    you as a message, and you will pick up from there. Anything the answer does
    not block, you can finish first.
    """
  end

  defp waiting_advice(_agent_id) do
    """
    They will not answer instantly. Do other work, or stop — the stop hook
    will bring you back. Call `check_answer` with that id for the reply.
    """
  end

  defp ask(%{user: %{id: user_id}} = scope, message, agent_id) do
    attrs = %{
      # Who to hand the answer back to.
      #
      # Off the connection (`Plugs.AgentScope`), not off a parameter: an agent
      # cannot state somebody else's id and does not have to state its own.
      # Nil for a Claude Code session, which has no agent and polls with
      # `check_answer` instead.
      "agent_id" => agent_id,
      "questions" => [
        %{"question" => message, "header" => nil, "multiSelect" => false, "options" => []}
      ],
      "title" => "Claude has a message",
      # A session or an agent, never both.
      "session_external_id" => session_id_unless_agent(agent_id, scope)
    }

    case Notifications.create_question_request(user_id, attrs) do
      {:ok, request} -> {:ok, request.id}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp ask(_scope, _message, _agent_id), do: {:error, :no_user}

  # Whose inbox this actually landed in.
  #
  # The reply used to say "Asked. The user has been notified", which is true and
  # tells an agent nothing it could act on. A typed MCP tool is bound to
  # whichever harness its session serves, with no parameter to redirect it — so
  # a QA agent exercising the ask→answer round trip from a worktree of the real
  # repo asks the *real* owner, sees "Asked", and moves on. It happened twice on
  # one story, and story 896 gave questions no dismiss and no expiry on purpose,
  # so both are permanent and only that owner can clear them (`08d4d7bd`).
  #
  # Naming the recipient does not prevent it — only a way to target another
  # harness would, and that is the real fix. It makes the mistake visible in the
  # one response the agent is certain to read, at the moment it is made rather
  # than when somebody finds the rows later.
  defp recipient(%{user: user} = scope) do
    case {user_label(user), scope.active_project} do
      {nil, _} -> "the user"
      {label, %{name: project}} when is_binary(project) -> "#{label} (project: #{project})"
      {label, _} -> label
    end
  end

  defp recipient(_scope), do: "the user"

  defp user_label(%{email: email}) when is_binary(email) and email != "", do: email
  defp user_label(%{id: id}) when not is_nil(id), do: "user #{id}"
  defp user_label(_), do: nil

  # The working copy this agent is in, when there is one. `HarnessScope` puts it
  # on the scope from the id in the MCP URL; a caller reaching this from
  # somewhere unaddressed has none, and the question is still asked — it simply
  # has no conversation to be shown in.
  defp working_copy_id(%{active_working_copy_id: id}) when is_binary(id), do: id
  defp working_copy_id(_scope), do: nil

  # A session or an agent, never both. `Sessions.external_id_for_harness/1`
  # answers nil for an agent's working copy anyway, so stamping it wrote
  # nothing — but naming both implied the two identities were interchangeable,
  # and a page reading the wrong one is what sent every agent question nowhere.
  defp session_id_unless_agent(agent_id, _scope) when is_binary(agent_id), do: nil

  defp session_id_unless_agent(_agent_id, scope),
    do: Sessions.external_id_for_harness(working_copy_id(scope))
end
