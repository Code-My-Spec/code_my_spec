defmodule CodeMySpec.McpServers.Tasks.Tools.AskUser do
  @moduledoc """
  Ask the user a free-form question. Returns once the question is delivered;
  the reply is collected separately with `check_answer`.

  Pushes the message to the user's phone (Web Push → `QuestionLive.Show`, which
  renders a free-text box for a question with no options). Unlike
  `AskUserQuestion`, there are no fixed options — use this for open-ended
  questions ("what should this copy say?", "how do you want this edge case
  handled?") or a check-in where enumerating choices would be artificial.

  ## Why this does not block

  It used to wait inline for the reply, up to ten minutes. That could never
  work: a tool call is dispatched through a `GenServer.call` whose timeout is
  measured in seconds, so the transport gave up long before any person could
  answer and the agent saw `-32603 Internal error`. Each attempt still created
  the question, so a user watching their queue saw the same thing asked over and
  over while the agent was told the tool was broken.

  Waiting minutes inside a synchronous call was the mistake, not the timeout
  value. A person is not a slow function; they are an event that arrives later.
  So this returns a question id and `check_answer` fetches the reply when the
  agent next looks. In between the agent can stop — the stop hook brings it
  back, which is the loop that already exists.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Notifications.QuestionClient

  schema do
    field :message, :string,
      required: true,
      doc: "The free-form question/message to send the user. They reply in prose."
  end

  @impl true
  def execute(%{message: message}, frame) when is_binary(message) and message != "" do
    question = %{
      "question" => message,
      "header" => nil,
      "multiSelect" => false,
      "options" => []
    }

    case QuestionClient.ask([question], "Claude has a message", harness_id(frame)) do
      {:ok, id} ->
        {:reply,
         Response.tool()
         |> Response.text("""
         Asked. The user has been notified.

         Question id: #{id}

         They will not answer instantly. Do other work, or stop — the stop hook
         will bring you back. Call `check_answer` with that id for the reply.
         """), frame}

      {:error, :not_configured} ->
        {:reply,
         Response.tool()
         |> Response.error(
           "Not connected to CodeMySpec, so the user can't be reached remotely. Ask in the terminal instead."
         ), frame}

      {:error, reason} ->
        {:reply,
         Response.tool() |> Response.error("Could not reach the user: #{inspect(reason)}"), frame}
    end
  end

  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.error("message is required"), frame}
  end

  # The working copy this agent is in, when there is one. `HarnessScope` puts it
  # on the scope from the id in the MCP URL; a caller reaching this from
  # somewhere unaddressed has none, and the question is still asked — it simply
  # has no conversation to be shown in.
  defp harness_id(%{assigns: %{current_scope: %{active_harness_id: id}}}) when is_binary(id),
    do: id

  defp harness_id(_frame), do: nil
end
