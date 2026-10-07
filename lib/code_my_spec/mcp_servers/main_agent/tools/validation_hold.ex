defmodule CodeMySpec.McpServers.MainAgent.Tools.ValidationHold do
  @moduledoc "Record, authorize and hand off serial validation. Listing includes terminal and unknown execution evidence; no action launches a run."
  use Anubis.Server.Component, type: :tool
  alias Anubis.Server.Response
  alias CodeMySpec.Analysis.ValidationHolds
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.ValidationHoldReport
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:action, :string,
      required: true,
      doc: "list, create, authorize, release or confirm_termination"
    )

    field(:hold_id, :string)

    field(:run_id, :integer,
      doc: "On create, adopt this project's existing active run rather than start another."
    )

    field(:reason, :string)

    field(:termination_evidence, :string,
      doc: "Verified terminal evidence for confirm_termination; never a guess or timeout alone."
    )

    field(:affected_copy_ids, {:list, :string})
    field(:authorized_copy_id, :string)
    field(:source, :string)
    field(:args, {:list, :string})
    field(:next_agent_id, :string)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         id when is_binary(id) <- frame.assigns[:agent_id],
         {:ok, %{role: :main}} <- AgentsRepository.fetch_agent(scope, id) do
      result = apply_action(scope, id, params)

      response =
        case result do
          {:ok, holds} when is_list(holds) ->
            Response.tool()
            |> Response.text(Enum.map_join(holds, "\n\n", &ValidationHoldReport.message/1))

          {:ok, hold} ->
            Response.tool() |> Response.text(ValidationHoldReport.message(hold))

          {:error, reason} ->
            Response.tool() |> Response.error(inspect(reason))
        end

      {:reply, response, frame}
    else
      _ ->
        {:reply,
         Response.tool()
         |> Response.error("Only this project's main agent may manage validation holds."), frame}
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
