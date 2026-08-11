defmodule CodeMySpec.McpServers.Architecture.Tools.ExecuteProposal do
  @moduledoc """
  Manually executes the architecture proposal at `.code_my_spec/architecture/proposal.md`.

  In patch mode the architect can choose between two paths: the small
  incremental tools (`create_component`, `set_story_component`) for one-off
  additions, or rewriting `proposal.md` for larger restructures. When the
  architect picks the rewrite path, this tool applies the rewritten proposal
  — reads the file, validates it, and creates/updates components and links.

  Returns success when the proposal is valid and execution completes, or an
  error response with feedback when validation fails.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        handle_evaluate(ArchitectureDesign.execute_proposal(scope), frame)

      {:error, reason} ->
        {:reply, ArchitectureMapper.error("Failed to execute proposal: #{inspect(reason)}"), frame}
    end
  end

  defp handle_evaluate({:ok, :valid}, frame) do
    {:reply, success("Proposal executed successfully."), frame}
  end

  defp handle_evaluate({:ok, :valid, warnings_section}, frame) do
    {:reply, success("Proposal executed.\n\n" <> warnings_section), frame}
  end

  defp handle_evaluate({:ok, :invalid, feedback}, frame) do
    {:reply, ArchitectureMapper.error(feedback), frame}
  end

  # Distinct from `:invalid`, which says the proposal is wrong. This says nobody
  # read it. Answering "unexpected evaluator result" would send the architect
  # looking for a defect in a proposal the server never opened (074b7c83).
  defp handle_evaluate({:error, reason}, frame) do
    if Environments.unobservable?(reason) do
      {:reply,
       ArchitectureMapper.error("""
       The proposal could not be read: this server holds no working copy, so \
       every file operation answers #{inspect(reason)}.

       Under a light harness that is normal — the harness watches the files. \
       Nothing is wrong with the proposal, and rewriting it will not help. \
       Report it with `create_issue` (scope: framework) and ask the user how to \
       proceed.
       """), frame}
    else
      {:reply, ArchitectureMapper.error("Failed to execute proposal: #{inspect(reason)}"), frame}
    end
  end

  defp handle_evaluate(other, frame) do
    {:reply, ArchitectureMapper.error("Unexpected evaluator result: #{inspect(other)}"), frame}
  end

  defp success(text) do
    Response.tool() |> Response.text(text)
  end
end
