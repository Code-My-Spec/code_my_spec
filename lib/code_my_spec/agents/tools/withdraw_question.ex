defmodule CodeMySpec.Agents.Tools.WithdrawQuestion do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents.Tools.CheckAnswer
  alias CodeMySpec.Notifications

  @impl true
  def name, do: "withdraw_question"

  @impl true
  def description do
    """
    Take back your own pending question once it is moot, with the reason. The
    task it blocked is released; resume it with start_task.
    """
  end

  @impl true
  def params do
    %{
      reason: {:required, {:meta, :string, [description: "Why it no longer needs an answer."]}},
      question_id:
        {:required, {:meta, :string, [description: "The id `ask_user_question` returned."]}}
    }
  end

  @impl true
  def call(%{question_id: id} = params, context) when is_binary(id) and id != "" do
    with {:ok, _request} <- CheckAnswer.owned_request(id, context),
         {:ok, request, released} <-
           Notifications.withdraw_question_request(id, Map.get(params, :reason) || "") do
      {:ok, withdrawn(request, released)}
    else
      {:error, reason} -> {:error, refused(id, reason)}
    end
  end

  def call(_params, _context) do
    {:error, "question_id and reason are required"}
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
