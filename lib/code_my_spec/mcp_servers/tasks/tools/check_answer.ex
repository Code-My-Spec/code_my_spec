defmodule CodeMySpec.McpServers.Tasks.Tools.CheckAnswer do
  @moduledoc """
  Fetch the reply to a question raised by `ask_user`.

  The other half of a deliberately two-step exchange. `ask_user` delivers the
  question and returns; this collects the answer whenever the agent gets round
  to asking for it.

  It polls briefly — long enough that a user already looking at the question
  answers within one call, short enough that the MCP transport never times out.
  Answering takes as long as it takes, so `pending` is an ordinary result rather
  than a failure: stop, let the stop hook bring you back, and check again.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Notifications.QuestionClient

  # Comfortably inside the transport's call timeout. The point is to catch the
  # case where the user is already looking at their phone, not to wait them out.
  @poll_window_ms 3_000

  schema do
    field :question_id, :string,
      required: true,
      doc: "The question id returned by `ask_user`."
  end

  @impl true
  def execute(%{question_id: id}, frame) when is_binary(id) and id != "" do
    case QuestionClient.await_answer(id, timeout_ms: @poll_window_ms) do
      {:ok, answers} ->
        reply = answers |> Map.values() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")
        {:reply, Response.tool() |> Response.text("The user replied:\n#{reply}"), frame}

      {:error, :timeout} ->
        {:reply,
         Response.tool()
         |> Response.text("""
         Still waiting on the user — not an error, they just haven't answered yet.

         Do something else useful, or stop. The stop hook will bring you back;
         check again with the same id then. Do not re-ask the same question —
         that queues a duplicate for them.
         """), frame}

      {:error, :expired} ->
        {:reply,
         Response.tool()
         |> Response.error("That question expired unanswered. Ask again if you still need it."),
         frame}

      {:error, :not_configured} ->
        {:reply,
         Response.tool()
         |> Response.error("Not connected to CodeMySpec, so answers can't be collected."), frame}

      {:error, reason} ->
        {:reply, Response.tool() |> Response.error("Could not check: #{inspect(reason)}"), frame}
    end
  end

  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.error("question_id is required"), frame}
  end
end
