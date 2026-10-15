defmodule CodeMySpec.McpServers.Tasks.Tools.WithdrawQuestion do
  @moduledoc """
  Take back your own pending question once it is moot, with the reason. The
  task it blocked is released; resume it with start_task.
  """

  # 8c91d5bc: a coder's question went moot minutes after it was asked, and with
  # no way to take it back its task waited on a customer for 20+ minutes.
  # Only the asker: `CheckAnswer.owned_request/2` is the same ownership rule
  # `check_answer` reads by.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.Notifications

  schema do
    field :question_id, :string, required: true, description: "The id `ask_user_question` returned."
    field :reason, :string, required: true, description: "Why it no longer needs an answer."
  end

  @impl true
  def execute(%{question_id: id} = params, frame) when is_binary(id) and id != "" do
    with {:ok, _request} <- CheckAnswer.owned_request(id, frame),
         {:ok, request, released} <-
           Notifications.withdraw_question_request(id, Map.get(params, :reason) || "") do
      {:reply, Response.tool() |> Response.text(withdrawn(request, released)), frame}
    else
      {:error, reason} -> {:reply, Response.tool() |> Response.error(refused(id, reason)), frame}
    end
  end

  def execute(_params, frame) do
    {:reply, Response.tool() |> Response.error("question_id and reason are required"), frame}
  end

  defp withdrawn(%{task_id: task_id} = request, released) when released > 0 do
    "Withdrew question #{request.id}. Task #{task_id} is released; resume it with `start_task`."
  end

  defp withdrawn(request, _released), do: "Withdrew question #{request.id}."

  defp refused(id, :not_found),
    do: "No pending question of yours has id `#{id}`. Only the agent that asked may withdraw it."

  defp refused(_id, :needs_a_reason),
    do: "Say why it no longer needs an answer; the reason is kept with the question."

  defp refused(_id, {:already_resolved, status}),
    do: "That question is already #{status}; there is nothing to withdraw."

  defp refused(_id, reason), do: "Could not withdraw: #{inspect(reason)}"
end
