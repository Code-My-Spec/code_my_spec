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
  # tell a slow sweep from a hung one. The result reaches the agent through
  # `Agents.message_agent/4`, which wakes it.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Promotion.Responses
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Promotion

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         agent_id when is_binary(agent_id) <- frame.assigns[:agent_id] do
      :ok = Promotion.promote_async(scope, agent_id)
      {:reply, Response.tool() |> Response.text(Responses.started()), frame}
    else
      # No agent on the connection. Refused rather than quietly falling back to
      # the blocking path: a caller that cannot be messaged would wait on a
      # result this tool never promises to return, and the fix is one tool over.
      nil ->
        {:reply, Response.tool() |> Response.error(Responses.no_agent()), frame}

      {:error, _reason} ->
        {:reply, Response.tool() |> Response.error(Responses.no_project()), frame}
    end
  end
end
