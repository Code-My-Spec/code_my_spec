defmodule CodeMySpec.Architecture.Tools.RegenerateProposal do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Architecture.ProposalProjector
  alias CodeMySpec.Components
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.LocalScope
  alias CodeMySpec.Architecture.Tools.Responses, as: ArchitectureMapper
  alias CodeMySpec.Paths
  alias CodeMySpec.WorkingCopies

  @impl true
  def name, do: "regenerate_proposal"

  @impl true
  def description do
    """
    Rewrite `proposal.md` from the architecture that actually exists.

    The round trip was half built. `Proposal.from_markdown/2` turns the document
    into components and has an MCP tool driving it; `ProposalProjector.project/1`
    turns components back into the document and had no caller anywhere — written,
    tested in shape, and unreachable.

    That gap is what makes revision mode awkward. A project with 910 components
    and no `proposal.md` is not undesigned; it is designed and undocumented, and
    the only way to get a document describing it was to write one by hand. This
    produces it from the database instead, which is the one source that already
    agrees with the spec stubs the graph is built from.

    Writes through the environment for the selected working copy, including a
    remote harness when the server does not hold the checkout.

    Not automatic. Regenerating discards whatever the file said, and a proposal
    under active edit is worth more than one that matches the database, so the
    overwrite is something a caller asks for rather than something a task does on
    its way past.
    """
  end

  @impl true
  def params do
    %{
      confirm:
        {:meta, :boolean,
         [
           description:
             "Must be true. Regenerating replaces proposal.md with the current architecture, discarding any unexecuted edits."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         :ok <- confirmed(params) do
      write(scope)
    else
      {:error, reason} -> ArchitectureMapper.error(reason)
    end
  end

  # A guard rather than a default, because the destructive direction is the
  # silent one: an unexecuted proposal is somebody's design work and the
  # database cannot reconstruct it.
  defp confirmed(%{confirm: true}), do: :ok

  defp confirmed(_params),
    do:
      {:error,
       "Pass confirm: true. This replaces #{Paths.proposal_path()} with the current " <>
         "architecture and any unexecuted edits in it are lost."}

  defp write(scope) do
    env = project_environment(scope)
    content = ProposalProjector.project(scope)

    with :ok <- describes_something(scope, content) do
      do_write(env, content)
    end
  end

  defp project_environment(%{active_working_copy_id: nil, active_project: project}),
    do: LocalScope.execution_context(project)

  defp project_environment(scope), do: WorkingCopies.execution_context(scope)

  # A proposal with no contexts, written over one that had them, is worse than
  # no proposal: it is a document that confidently describes an empty
  # architecture, and the file it replaced is gone.
  #
  # Not hypothetical. The first real call to this tool did exactly that — the
  # projector emitted `## Contexts` and `## Surface Components` empty against 45
  # contexts in the database, because it only looked at components with no
  # parent and every context here hangs off the app's root namespace anchor.
  # `confirm: true` was given and honoured; consent is not a check on the
  # content.
  #
  # So the shape of the output is compared against the database it came from.
  # This would have caught that bug on the way out, and it catches the next one
  # of its kind without knowing what it is.
  defp describes_something(scope, content) do
    context_count =
      scope
      |> Components.list_components_with_dependencies()
      |> Enum.count(&(&1.type == "context"))

    if context_count > 0 and not String.contains?(content, "### ") do
      ArchitectureMapper.error("""
      Refusing to write: the generated proposal contains no components, but the \
      project has #{context_count} context(s).

      That is a projection bug rather than an empty architecture, and writing it \
      would replace whatever #{Paths.proposal_path()} says with a document \
      describing nothing.
      """)
    else
      :ok
    end
  end

  defp do_write(env, content) do
    case ExecutionContexts.write_file(env, Paths.proposal_path(), content) do
      :ok ->
        text("""
        # Proposal Regenerated

        `#{Paths.proposal_path()}` now describes the architecture in the database.

        Edit it and call `execute_proposal` to apply changes, or use
        `create_component` / `set_story_component` for incremental ones — those
        write their own stubs and need no proposal at all.
        """)

      # The same shape `create_component` uses when it cannot write: hand back
      # what would have been written rather than reporting success over a file
      # that does not exist.
      {:error, reason} ->
        text("""
        # Not Written

        Could not write `#{Paths.proposal_path()}` (#{inspect(reason)}). The
        content is below — the architecture it describes is correct, only the
        write failed.

        ```markdown
        #{content}
        ```
        """)
    end
  end

  defp text(content) do
    {:ok, content}
  end
end
