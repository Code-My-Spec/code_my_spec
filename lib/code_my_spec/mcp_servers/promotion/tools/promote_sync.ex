defmodule CodeMySpec.McpServers.Promotion.Tools.PromoteSync do
  @moduledoc """
  Put this working copy's finished work on the checkout the application runs
  from, and wait for the outcome.

  The external door. `Promote` is the one an Alloy agent uses: it returns at
  once and messages the result back, because an agent has a conversation to be
  told in. A caller reaching in over MCP has nowhere to be messaged, so this
  one blocks and answers.

  It is the same promotion either way — both call `Promotion.promote/1`. Only
  the delivery differs.

  Gates first: the copy must carry no problems, against a fresh analyzer sweep,
  and nothing uncommitted. Then merges this copy's branch into the running
  checkout, checks the merge added no problems there, restarts the application,
  and reports the revision it is now serving.

  Takes no arguments. The target is the project's designated main working copy,
  so there is no branch to name and no way to name the wrong one.
  """

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
      {:ok, scope} -> {:reply, Responses.respond(Promotion.promote(scope)), frame}
      {:error, _reason} -> {:reply, Response.tool() |> Response.error(Responses.no_project()), frame}
    end
  end
end
