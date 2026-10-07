defmodule CodeMySpec.McpServers.MainAgent.Tools.CompletionHandoff do
  @moduledoc "Assign reviewed artifact preservation, inspect completions, and explicitly acknowledge their next action. No action certifies QA or starts promotion."
  use Anubis.Server.Component, type: :tool
  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.CompletionHandoffs
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:action, :string, required: true, doc: "list, assign, acknowledge or redeliver")
    field(:handoff_id, :string)
    field(:owner_agent_id, :string)
    field(:working_copy_id, :string)
    field(:task_id, :string)
    field(:identity, :string)
    field(:artifact_paths, {:list, :string})
    field(:reviewed_base, :string)
    field(:reviewed_diff, :string)
    field(:purpose, :string)
    field(:authorship, :string)
    field(:next_action, :string)
    field(:acknowledgement, :string)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         id when is_binary(id) <- frame.assigns[:agent_id],
         %{id: ^id} <- Agents.main_agent(scope) do
      response =
        case apply_action(scope, id, params) do
          {:ok, rows} when is_list(rows) ->
            Response.tool()
            |> Response.text(Enum.map_join(rows, "\n\n", &CompletionHandoffs.message/1))

          {:ok, row} ->
            Response.tool() |> Response.text(CompletionHandoffs.message(row))

          {:error, reason} ->
            Response.tool() |> Response.error(inspect(reason))
        end

      {:reply, response, frame}
    else
      _ ->
        {:reply,
         Response.tool()
         |> Response.error("Only this project's main agent may manage completion handoffs."),
         frame}
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
