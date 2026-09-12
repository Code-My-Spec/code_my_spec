defmodule CodeMySpec.McpServers.Promotion.Tools.Promote do
  @moduledoc """
  Put your finished work on the checkout the application runs from, so QA tests
  the code you wrote.

  Returns as soon as the promotion starts; the outcome arrives as a message.
  Takes no arguments — there is one place work goes.
  """

  # Kept short deliberately: `Anubis.Server.Component` advertises the moduledoc
  # as this tool's `description`, so every word is sent to every agent at
  # connect and criterion 2999 caps that payload at a quarter of the 82,591
  # bytes it was. Registering this tool and `promote_sync` at full length blew
  # it: 21,878 against a 20,647 budget. The detail lives here instead.
  #
  # What it does, in order: refuses if this copy has uncommitted work; gates on
  # the copy carrying no problems against a fresh analyzer sweep; merges this
  # copy's branch into the running checkout; checks the merge added no problems
  # there; restarts the application; reports the revision it is serving.
  #
  # Promoting *from* the running copy is a restart and nothing else — no merge,
  # no gate, no sweep, because nothing crosses. That is the case where the code
  # is already in place and the application is simply not up.
  #
  # Async for the same reason `start_analysis` is: the sweep takes minutes, and
  # a tool call held open for it blocks an agent with no output and no way to
  # tell a slow sweep from a hung one. An Alloy agent is told through
  # `Agents.dispatch_message/3`, which wakes it.
  #
  # Async for *everyone*, including a connection with no agent on it. This used
  # to refuse those and point at `promote_sync`, which meant the one caller that
  # could not be messaged was sent to the one tool that waits minutes over a
  # transport that gives up in thirty seconds. A Claude Code session promoting
  # this way got a timeout for a promotion that had already merged and
  # restarted, retried it, and restarted the shared dev server three times
  # (88247a09).
  #
  # A caller with nowhere to be messaged learns the outcome the same way
  # `start_analysis` offers: the log records it either way, and
  # `POST /api/harnesses/<working_copy_id>/promotion/run` is the door that
  # blocks for the whole thing without a cap. See `CmsHarness.Web.PromotionController`.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Promotion.Responses
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Promotion

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        :ok = Promotion.promote_async(scope, frame.assigns[:agent_id])

        {:reply,
         Response.tool()
         |> Response.text(Responses.started(scope.active_working_copy_id)), frame}

      {:error, _reason} ->
        {:reply, Response.tool() |> Response.error(Responses.no_project()), frame}
    end
  end
end
