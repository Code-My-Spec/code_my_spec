defmodule CodeMySpec.Agents.Tools.ValidationHold do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Analysis.ValidationHolds
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.ValidationHoldReport

  @impl true
  def name, do: "validation_hold"

  @impl true
  def description do
    "Record, authorize and hand off serial validation. Listing includes terminal and unknown execution evidence; no action launches a run."
  end

  @impl true
  def params do
    %{
      args: {:list, :string},
      reason: :string,
      source: :string,
      action:
        {:required,
         {:meta, :string,
          [description: "list, create, authorize, release or confirm_termination"]}},
      affected_copy_ids: {:list, :string},
      authorized_copy_id: :string,
      hold_id: :string,
      next_agent_id: :string,
      run_id:
        {:meta, :integer,
         [
           description:
             "On create, adopt this project's existing active run rather than start another."
         ]},
      termination_evidence:
        {:meta, :string,
         [
           description:
             "Verified terminal evidence for confirm_termination; never a guess or timeout alone."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         id when is_binary(id) <- context[:agent_id],
         {:ok, %{role: :main}} <- AgentsRepository.fetch_agent(scope, id) do
      result = apply_action(scope, id, params)

      response =
        case result do
          {:ok, holds} when is_list(holds) ->
            {:ok, Enum.map_join(holds, "\n\n", &ValidationHoldReport.message/1)}

          {:ok, hold} ->
            {:ok, ValidationHoldReport.message(hold)}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      response
    else
      _ ->
        {:error, "Only this project's main agent may manage validation holds."}
    end
  end

  defp apply_action(scope, _owner, %{action: "list"}), do: {:ok, ValidationHolds.list(scope)}

  defp apply_action(scope, owner, %{action: "create"} = params),
    do:
      ValidationHolds.create(
        scope,
        params
        |> Map.take([:reason, :affected_copy_ids, :next_agent_id, :run_id])
        |> Map.put(:owner_agent_id, owner)
      )

  defp apply_action(scope, owner, %{action: "authorize", hold_id: id} = params),
    do:
      ValidationHolds.authorize(
        scope,
        id,
        owner,
        Map.take(params, [:authorized_copy_id, :source, :args, :next_agent_id])
      )

  defp apply_action(scope, owner, %{action: "release", hold_id: id}),
    do: ValidationHolds.release(scope, id, owner)

  defp apply_action(scope, owner, %{
         action: "confirm_termination",
         hold_id: id,
         termination_evidence: evidence
       })
       when is_binary(evidence) and byte_size(evidence) > 0,
       do: ValidationHolds.confirm_termination(scope, id, owner, evidence)

  defp apply_action(_scope, _owner, _params), do: {:error, :invalid_action}
end
