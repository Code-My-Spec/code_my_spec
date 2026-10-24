defmodule CodeMySpec.McpServers.Promotion.Tools.Promote do
  @moduledoc """
  Publish verified work to the project's remote development branch.

  Queues your committed HEAD for source-device certification and answers with
  its place. The queue publishes the exact verified candidate and reports the
  outcome. Name the story to stamp its publication. Destination updates and
  preview health are tracked separately; an offline desktop does not block it.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Promotion.Responses
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.PromotionQueue

  schema do
    field :story_number, :integer,
      description:
        "The story being promoted. Latched and stamped only if its spex pass. " <>
          "Omit for work that is not a story's, such as a fix from an issue."

    field :restart, :boolean, description: "Restart the app instead of reloading it."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        # An in-app agent is told when the detached restart confirms or fails;
        # no agent id (a Claude Code session, an operator) tells nobody.
        result =
          PromotionQueue.promote(scope, params[:story_number],
            notify: frame.assigns[:agent_id],
            restart: params[:restart] == true
          )

        mark_awaiting(result, frame)

        {:reply, Responses.respond(result), frame}

      {:error, _reason} ->
        {:reply, Response.tool() |> Response.error(Responses.no_project()), frame}
    end
  end

  # A queued promotion leaves its `story_promoted`/`promote_issue` task open until
  # the batch lands, and that task must not hold the agent's only slot — while
  # main was red it could not close and the agent stayed parked on work it could
  # take no action on (issue e515bff3, story 1091).
  #
  # The wait is written onto the task's own row here, after the queue has
  # answered, so `TaskOwner.allow_activation/2` reads its own row and asks the
  # queue nothing. This is the one layer that may: it depends on `Agents` and on
  # `PromotionQueue`, where the queue's own callers sit below `Agents` and could
  # only close a cycle (issue e23a5547).
  #
  # Best-effort: the promotion is already queued, and a task that could not be
  # marked changes only how the agent's *next* claim is allowed, never whether
  # this promotion lands. Failing the call here would report a promotion as
  # refused when it is running.
  defp mark_awaiting(%{queued: %{subject_type: type, subject_id: id}}, frame)
       when is_binary(id) do
    case frame.assigns[:agent_id] do
      agent_id when is_binary(agent_id) ->
        mark(agent_id, type, id)

      _no_agent ->
        :ok
    end
  end

  defp mark_awaiting(_result, _frame), do: :ok

  defp mark(agent_id, type, id) do
    case Agents.await_promotion(agent_id, to_string(type), id) do
      :ok ->
        :ok

      {:ok, _marked} ->
        :ok

      {:error, reason} ->
        Logger.warning("promote: could not mark task awaiting: #{inspect(reason)}")
    end
  end
end
