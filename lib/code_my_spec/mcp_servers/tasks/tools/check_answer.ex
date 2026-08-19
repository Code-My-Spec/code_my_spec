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

  ## Why this no longer goes over HTTP

  The same reason `ask_user` stopped, in its own words: this runs *in* the cloud
  app, in the same process as `Notifications` and against the same database, so
  the request left the VM and came back to call the function that was already in
  scope.

  Story 896 moved `ask_user` and added `list_user_questions` in-process, and left
  this one on `QuestionClient` — so the half of the exchange that *collects* the
  answer was the half no spex could drive, and the only untested step in a flow
  built to be tested. They were verified to reach the same database, so nothing
  was broken; it was a round trip and a blind spot rather than a split brain.

  `QuestionClient` stays for the CLI, which genuinely is a different process.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Notifications

  # Comfortably inside the transport's call timeout. The point is to catch the
  # case where the user is already looking at their phone, not to wait them out.
  @poll_window_ms 3_000
  @poll_interval_ms 250

  schema do
    field :question_id, :string,
      required: true,
      doc: "The question id returned by `ask_user`."
  end

  @impl true
  def execute(%{question_id: id}, frame) when is_binary(id) and id != "" do
    case await_answer(id) do
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

  # Same contract `QuestionClient.await_answer/2` had — `{:ok, answers}`,
  # `{:error, :timeout}`, `{:error, reason}` — so every branch below is
  # unchanged. Only where the answer is read from moved.
  #
  # Polling rather than subscribing because the caller is a tool invocation with
  # a deadline, not a process that can wait: it either has an answer inside the
  # transport's window or it says `pending` and the agent stops. A PubSub
  # subscription would be the right shape for something that can block, and this
  # deliberately cannot.
  defp await_answer(id) do
    deadline = System.monotonic_time(:millisecond) + @poll_window_ms
    poll(id, deadline)
  end

  defp poll(id, deadline) do
    case Notifications.get_question_request(id) do
      nil ->
        {:error, :not_found}

      %{status: "answered", answers: answers} when is_map(answers) ->
        {:ok, answers}

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@poll_interval_ms)
          poll(id, deadline)
        end
    end
  end
end
