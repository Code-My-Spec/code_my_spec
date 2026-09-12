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

  `QuestionClient` is gone entirely — 3b038c842 removed it with the rest of the
  arbitrage path. This paragraph said it "stays for the CLI", which was true when
  written and outlived the module by two days.
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

      {:error, {:pending, holder}} ->
        {:reply, Response.tool() |> Response.text(still_open(holder)), frame}

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

  # What "still open" means, said precisely enough to act on.
  #
  # Criterion 3269. This used to answer "waiting on the user" for every pending
  # question, which was true of the only path that existed then and is a guess
  # now: a question an agent raised waits on the project's main agent first and
  # reaches the user only if it is escalated. An agent told the wrong one cannot
  # tell a chain that is progressing normally from one that has stalled, and its
  # only options are to poll forever or to give up on work that is merely
  # waiting.
  #
  # Neither is an error and neither is a reason to stop trying. The difference
  # is what a stalled chain would look like, and therefore when to say something
  # about it.
  defp still_open("main_agent") do
    """
    Still waiting on the main agent — not an error, it just hasn't got to this yet.

    It answers what the project already records and passes the rest to the user,
    so this may be settled without anybody being interrupted.

    Do something else useful, or stop. The stop hook will bring you back; check
    again with the same id then. Do not re-ask the same question — that queues a
    duplicate.
    """
  end

  defp still_open(_holder) do
    """
    Still waiting on the user — not an error, they just haven't answered yet.

    Do something else useful, or stop. The stop hook will bring you back;
    check again with the same id then. Do not re-ask the same question —
    that queues a duplicate for them.
    """
  end

  # Same contract `QuestionClient.await_answer/2` had — `{:ok, answers}` and
  # `{:error, reason}` — except that a pending question now carries who it is
  # pending on, because "still waiting" without a holder is not enough for the
  # agent to know what it is waiting for.
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

      %{holder: holder} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:pending, holder}}
        else
          Process.sleep(@poll_interval_ms)
          poll(id, deadline)
        end
    end
  end
end
