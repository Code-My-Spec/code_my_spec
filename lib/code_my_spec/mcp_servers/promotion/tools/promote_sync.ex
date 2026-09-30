defmodule CodeMySpec.McpServers.Promotion.Tools.PromoteSync do
  @moduledoc """
  Promote this working copy's finished work, and wait for the outcome.

  Same promotion as `promote`; this one blocks and answers instead of messaging
  back. For callers with no agent behind them. Takes the story number.
  """

  # Kept short deliberately — see the note in `Promote`. Both descriptions are
  # sent to every agent at connect, and criterion 2999 caps that payload.
  #
  # The external door. `Promote` is the one an Alloy agent uses: it has a
  # conversation to be told in. A caller reaching in over MCP has nowhere to be
  # messaged, so this one waits.
  #
  # It is the same promotion either way — both call `Promotion.promote/1`, and
  # only the delivery differs. Minutes, when the gate sweeps analyzers.

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
