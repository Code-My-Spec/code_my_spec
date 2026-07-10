defmodule CodeMySpec.McpServers.Tasks.Tools.AskUser do
  @moduledoc """
  Ask the user a free-form question and block until they answer.

  Pushes the message to the user's phone (Web Push → `QuestionLive.Show`, which
  renders a free-text box for a question with no options) and waits for their
  typed reply, returned as the tool result. Unlike `AskUserQuestion`, there are
  no fixed options — use this in autonomous/loop work for open-ended questions
  ("what should this copy say?", "how do you want this edge case handled?") or a
  conversational check-in where enumerating choices would be artificial.

  Best-effort: returns a clear error (rather than hanging) when the user isn't
  connected to CodeMySpec or doesn't answer within the timeout, so the caller
  can fall back to a sensible default or the local terminal prompt.
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

    with {:ok, id} <- QuestionClient.ask([question], "Claude has a message"),
         {:ok, answers} <- QuestionClient.await_answer(id) do
      reply = Map.get(answers, message) || (answers |> Map.values() |> List.first()) || ""
      {:reply, Response.tool() |> Response.text("The user replied:\n#{reply}"), frame}
    else
      {:error, :not_configured} ->
        {:reply,
         Response.tool()
         |> Response.error(
           "Not connected to CodeMySpec, so the user can't be reached remotely. Ask in the terminal instead."
         ), frame}

      {:error, :timeout} ->
        {:reply,
         Response.tool()
         |> Response.error(
           "The user hasn't answered yet (timed out). Proceed with a sensible default, or try again later."
         ), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Could not reach the user: #{inspect(reason)}"), frame}
    end
  end

  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.error("message is required"), frame}
  end
end
