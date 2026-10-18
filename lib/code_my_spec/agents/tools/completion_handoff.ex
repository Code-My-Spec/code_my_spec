defmodule CodeMySpec.Agents.Tools.CompletionHandoff do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.CompletionHandoffs

  @impl true
  def name, do: "completion_handoff"

  @impl true
  def description do
    "Assign reviewed artifact preservation, inspect completions, and explicitly acknowledge their next action. No action certifies QA or starts promotion."
  end

  @impl true
  def params do
    %{
      action:
        {:required, {:meta, :string, [description: "list, assign, acknowledge or redeliver"]}},
      identity: :string,
      working_copy_id: :string,
      task_id: :string,
      acknowledgement: :string,
      artifact_paths: {:list, :string},
      authorship: :string,
      handoff_id: :string,
      next_action: :string,
      owner_agent_id: :string,
      purpose: :string,
      reviewed_base: :string,
      reviewed_diff: :string
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         id when is_binary(id) <- context[:agent_id],
         %{id: ^id} <- Agents.main_agent(scope) do
      response =
        case apply_action(scope, id, params) do
          {:ok, rows} when is_list(rows) ->
            {:ok, Enum.map_join(rows, "\n\n", &CompletionHandoffs.message/1)}

          {:ok, row} ->
            {:ok, CompletionHandoffs.message(row)}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      response
    else
      _ ->
        {:error, "Only this project's main agent may manage completion handoffs."}
    end
  end

  defp apply_action(scope, _id, %{action: "list"}), do: {:ok, CompletionHandoffs.list(scope)}

  defp apply_action(scope, id, %{action: "assign"} = params),
    do:
      CompletionHandoffs.assign(
        scope,
        id,
        Map.take(params, [
          :owner_agent_id,
          :working_copy_id,
          :task_id,
          :identity,
          :artifact_paths,
          :reviewed_base,
          :reviewed_diff,
          :purpose,
          :authorship,
          :next_action
        ])
      )

  defp apply_action(scope, id, %{
         action: "acknowledge",
         handoff_id: handoff,
         acknowledgement: note
       })
       when is_binary(note) and byte_size(note) > 0,
       do: CompletionHandoffs.acknowledge(scope, id, handoff, note)

  defp apply_action(scope, id, %{action: "redeliver", handoff_id: handoff}),
    do: CompletionHandoffs.redeliver(scope, id, handoff)

  defp apply_action(_scope, _id, _params), do: {:error, :invalid_action}
end
