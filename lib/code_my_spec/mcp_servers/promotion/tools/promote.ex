defmodule CodeMySpec.McpServers.Promotion.Tools.Promote do
  @moduledoc """
  Put your finished work on the checkout the application runs from, so QA tests
  the code you wrote.

  Queues your HEAD and answers at once with its place. The queue gates it on
  main with the candidates ahead of it and lands it when green; you are told
  when it lands, or why it was taken out. Name the story: it is latched and
  stamped promoted only if its spex pass.
  """

  # Kept short deliberately: `Anubis.Server.Component` advertises the moduledoc
  # as this tool's `description`, so every word is sent to every agent at
  # connect and criterion 2999 caps that payload at a quarter of the 82,591
  # bytes it was. Registering this tool and `promote_sync` at full length blew
  # it: 21,878 against a 20,647 budget. The detail lives here instead.
  #
  # What it does, in order: refuses if this copy is behind main or has
  # uncommitted work; gates on clean analyzer runs at its HEAD (starting any
  # that are missing and answering pending); merges exactly that commit into
  # the running checkout; reloads the application, or restarts it when the
  # change needs that or `restart` is set; reports what it serves.
  #
  # Promoting *from* the running copy is a restart and nothing else — no merge,
  # no gate, no sweep, because nothing crosses. That is the case where the code
  # is already in place and the application is simply not up.
  #
  # Synchronous, because nothing in it is long-running.
  #
  # It used to be async "for the same reason `start_analysis` is: the sweep
  # takes minutes". That reason expired at 54aa534c, when `gate/1` stopped
  # running a sweep and became a read of the runs already on file. What remains
  # is three DB reads, a `git status`, a `--ff-only` merge and a detached
  # restart — 0.3s end to end in `AsyncDeploymentTest`.
  #
  # Being async was not free. Every refusal is decided before the merge, so
  # `promote` answered "Promotion started." to a promotion it had already
  # declined, and reported the real outcome through a channel only Alloy agents
  # have. For a Claude Code session, a script or curl, the refusal existed only
  # in `web.log`. A false success is worse than an error: the caller waits, then
  # checks whether `main` moved, and that looks exactly like a slow promotion.
  #
  # The restart is the one thing still not waited on, and `Promotion.outcome_text/1`
  # says so in the answer rather than leaving it to be discovered.

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Promotion.Responses
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.PromotionQueue

  schema do
    field :story_number, :integer,
      doc:
        "The story being promoted. Latched and stamped only if its spex pass. " <>
          "Omit for work that is not a story's, such as a fix from an issue."

    field :restart, :boolean, doc: "Restart the app instead of reloading it."
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
      :ok -> :ok
      {:ok, _marked} -> :ok
      {:error, reason} -> Logger.warning("promote: could not mark task awaiting: #{inspect(reason)}")
    end
  end
end
