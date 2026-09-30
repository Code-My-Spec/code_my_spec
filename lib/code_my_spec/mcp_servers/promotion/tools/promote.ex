defmodule CodeMySpec.McpServers.Promotion.Tools.Promote do
  @moduledoc """
  Put your finished work on the checkout the application runs from, so QA tests
  the code you wrote.

  Answers when the merge is done, or says why it was refused. The restart runs
  detached and the answer says so. Name the story: it is latched and stamped
  promoted only if its spex pass, else refused.
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
  # the running checkout; restarts the application; reports what it serves.
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

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Promotion.Responses
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Promotion

  schema do
    field :story_number, :integer,
      doc:
        "The story being promoted. Latched and stamped only if its spex pass. " <>
          "Omit for work that is not a story's, such as a fix from an issue."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        # An in-app agent is told when the detached restart confirms or fails;
        # no agent id (a Claude Code session, an operator) tells nobody.
        result = Promotion.promote(scope, params[:story_number], notify: frame.assigns[:agent_id])
        {:reply, Responses.respond(result), frame}

      {:error, _reason} ->
        {:reply, Response.tool() |> Response.error(Responses.no_project()), frame}
    end
  end
end
