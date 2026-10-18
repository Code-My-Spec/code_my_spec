defmodule CodeMySpec.Architecture.Tools.ExecuteProposal do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Environments
  alias CodeMySpec.Architecture.Tools.Responses, as: ArchitectureMapper

  @impl true
  def name, do: "execute_proposal"

  @impl true
  def description do
    """
    Manually executes the architecture proposal at `.code_my_spec/architecture/proposal.md`.

    In patch mode the architect can choose between two paths: the small
    incremental tools (`create_component`, `set_story_component`) for one-off
    additions, or rewriting `proposal.md` for larger restructures. When the
    architect picks the rewrite path, this tool applies the rewritten proposal
    — reads the file, validates it, and creates/updates components and links.

    Returns success when the proposal is valid and execution completes, or an
    error response with feedback when validation fails.
    """
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        handle_evaluate(ArchitectureDesign.execute_proposal(scope), context)

      {:error, reason} ->
        ArchitectureMapper.error("Failed to execute proposal: #{inspect(reason)}")
    end
  end

  defp handle_evaluate({:ok, :valid}, _context) do
    success("Proposal executed successfully.")
  end

  defp handle_evaluate({:ok, :valid, warnings_section}, _context) do
    success("Proposal executed.\n\n" <> warnings_section)
  end

  defp handle_evaluate({:ok, :invalid, feedback}, _context) do
    ArchitectureMapper.error(feedback)
  end

  # Distinct from `:invalid`, which says the proposal is wrong. This says nobody
  # read it. Answering "unexpected evaluator result" would send the architect
  # looking for a defect in a proposal the server never opened (074b7c83).
  defp handle_evaluate({:error, reason}, _context) do
    if Environments.unobservable?(reason) do
      ArchitectureMapper.error("""
      The proposal could not be read: this server holds no working copy, so \
      every file operation answers #{inspect(reason)}.

      Under a light harness that is normal — the harness watches the files. \
      Nothing is wrong with the proposal, and rewriting it will not help. \
      Report it with `create_issue` (scope: framework) and ask the user how to \
      proceed.
      """)
    else
      ArchitectureMapper.error("Failed to execute proposal: #{inspect(reason)}")
    end
  end

  defp handle_evaluate(other, _context) do
    ArchitectureMapper.error("Unexpected evaluator result: #{inspect(other)}")
  end

  defp success(text) do
    {:ok, text}
  end
end
