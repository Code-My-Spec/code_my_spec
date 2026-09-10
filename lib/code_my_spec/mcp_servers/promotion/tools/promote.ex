defmodule CodeMySpec.McpServers.Promotion.Tools.Promote do
  @moduledoc """
  Put your finished work on the checkout the application runs from, so QA tests
  the code you wrote.

  Returns as soon as the promotion starts. The outcome arrives as a message,
  because the analyzer sweep the gate waits on takes minutes and there is
  nothing useful you could do while a tool call held you there.

  Gates first: your copy must carry no problems, against a fresh sweep, and
  nothing uncommitted. Then merges your branch into the running checkout,
  checks the merge added no problems there, restarts the application, and tells
  you the revision it is serving.

  Takes no arguments. The target is the project's designated main working copy
  — there is one place work goes, so there is no branch to name.

  A caller with no agent behind it has nowhere to be messaged; that is what
  `promote_sync` is for.
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
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         agent_id when is_binary(agent_id) <- frame.assigns[:agent_id] do
      :ok = Promotion.promote_async(scope, agent_id)
      {:reply, Response.tool() |> Response.text(Responses.started()), frame}
    else
      # No agent on the connection. Refused rather than quietly falling back to
      # the blocking path: a caller that cannot be messaged would wait on a
      # result this tool never promises to return, and the fix is one tool over.
      nil -> {:reply, Response.tool() |> Response.error(Responses.no_agent()), frame}
      {:error, _reason} -> {:reply, Response.tool() |> Response.error(Responses.no_project()), frame}
    end
  end
end
