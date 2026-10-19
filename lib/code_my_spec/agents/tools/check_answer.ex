defmodule CodeMySpec.Agents.Tools.CheckAnswer do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Notifications

  # Comfortably inside the transport's call timeout. The point is to catch the
  # case where the user is already looking at their phone, not to wait them out.
  @answer_window_ms 3_000

  @impl true
  def name, do: "check_answer"

  @impl true
  def description do
    """
    Fetch the reply to a question raised by `ask_user`.

    The other half of a deliberately two-step exchange. `ask_user` delivers the
    question and returns; this collects the answer whenever the agent gets round
    to asking for it.

    It waits briefly for an answer event — long enough that a user looking at the question
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
  end

  @impl true
  def params do
    %{
      question_id:
        {:required, {:meta, :string, [description: "The question id returned by `ask_user`."]}}
    }
  end

  @impl true
  def call(%{question_id: id}, context) when is_binary(id) and id != "" do
    case await_answer(id, context) do
      {:ok, request} ->
        reply =
          request.answers |> Map.values() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("\n")

        {:ok, labeled(request, reply)}

      {:error, {:pending, holder}} ->
        {:ok, still_open(holder)}

      {:error, {:withdrawn, reason}} ->
        {:ok, "You withdrew this question: #{reason}. Nothing will answer it."}

      {:error, :not_found} ->
        {:error, not_found(id)}

      {:error, :not_configured} ->
        {:error, "Not connected to CodeMySpec, so answers can't be collected."}

      {:error, reason} ->
        {:error, "Could not check: #{inspect(reason)}"}
    end
  end

  def call(_params, _context) do
    {:error, "question_id is required"}
  end

  # Agents shorten ids in their own notes and then call with the short form
  # (2999a0cb), so say which id and where the whole one is.
  defp not_found(id) do
    "No question of yours has id `#{id}`. Use the full id — `list_user_questions` lists them."
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

  defp still_open("product_agent") do
    """
    Still waiting on the product agent — not an error. It owns the story's
    criteria and spec, and answers or passes the question to the user.

    Do something else useful, or stop, and check again with the same id later.
    Do not re-ask the same question — that queues a duplicate.
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

  # Who actually answered, said precisely enough to weigh. Criterion 3219: a
  # main agent's answer is a reading of the project's records and can be
  # wrong about intent, where the user's is the intent itself — an agent that
  # cannot tell them apart argues with the user on the strength of something
  # a peer told it earlier.
  #
  # `overruled` first and separately from `answered_by`, because after an
  # override `answered_by` correctly reads "user" — the same as an ordinary
  # first answer — and the fact that an earlier, different answer existed is
  # exactly what a question the main agent answered wrongly needs to say
  # (3220).
  defp labeled(%{overruled: true}, reply),
    do: "The user replied, overruling the main agent's earlier answer:\n#{reply}"

  defp labeled(%{answered_by: "main_agent"}, reply),
    do: "The main agent replied, from project records:\n#{reply}"

  defp labeled(%{answered_by: "product_agent"}, reply),
    do: "The product agent replied, as the owner of the criteria:\n#{reply}"

  defp labeled(_request, reply), do: "The user replied:\n#{reply}"

  # Same contract `QuestionClient.await_answer/2` had — `{:ok, answers}` and
  # `{:error, reason}` — except that a pending question now carries who it is
  # pending on, because "still waiting" without a holder is not enough for the
  # agent to know what it is waiting for.
  #
  # Subscribe before reading so an answer committed between the read and wait
  # cannot be missed. The receive is bounded by the transport's deadline.
  defp await_answer(id, context) do
    with {:ok, _request} <- owned_request(id, context) do
      subscribe_and_wait(id, context)
    end
  end

  @doc """
  The question `id`, if the caller asked it: the same agent, or an unowned
  question the same user asked. `{:error, :not_found}` otherwise, whoever else's it is.
  """
  @spec owned_request(String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def owned_request(id, context) do
    case Notifications.get_question_request(id) do
      nil ->
        {:error, :not_found}

      request ->
        if owned?(request, context), do: {:ok, request}, else: {:error, :not_found}
    end
  end

  defp owned?(request, %{scope: scope} = context) do
    case Agents.caller_agent_id(scope, context) do
      id when is_binary(id) ->
        request.agent_id == id and match?({:ok, _}, Agents.fetch_agent(scope, id))

      nil ->
        owned_by_user?(request, scope)
    end
  end

  defp owned?(_request, _context), do: false

  # A caller that is no agent owns the unowned questions its user asked.
  defp owned_by_user?(request, %{user: %{id: user_id}}),
    do: is_nil(request.agent_id) and request.user_id == user_id

  defp owned_by_user?(_request, _scope), do: false

  defp subscribe_and_wait(id, context) do
    topic = "question_request:#{id}"
    :ok = Phoenix.PubSub.subscribe(CodeMySpec.PubSub, topic)

    try do
      await_record(id, context, System.monotonic_time(:millisecond) + @answer_window_ms)
    after
      Phoenix.PubSub.unsubscribe(CodeMySpec.PubSub, topic)
    end
  end

  defp await_record(id, context, deadline) do
    case owned_request(id, context) do
      {:error, _} = error ->
        error

      {:ok, %{status: "answered", answers: answers} = request} when is_map(answers) ->
        {:ok, request}

      {:ok, %{status: "withdrawn", withdrawn_reason: reason}} ->
        {:error, {:withdrawn, reason}}

      {:ok, %{holder: holder}} ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:question_answered, %{id: ^id}} -> await_record(id, context, deadline)
        after
          remaining -> {:error, {:pending, holder}}
        end
    end
  end
end
