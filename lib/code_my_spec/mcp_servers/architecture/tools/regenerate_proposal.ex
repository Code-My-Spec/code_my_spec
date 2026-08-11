defmodule CodeMySpec.McpServers.Architecture.Tools.RegenerateProposal do
  @moduledoc """
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

  Writes through the scope's environment, so it works against a remote harness
  the same way `create_component`'s stub writing does — the server holds no
  checkout and does not need one.

  Not automatic. Regenerating discards whatever the file said, and a proposal
  under active edit is worth more than one that matches the database, so the
  overwrite is something a caller asks for rather than something a task does on
  its way past.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Architecture.ProposalProjector
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Paths

  schema do
    field :confirm, :boolean,
      doc:
        "Must be true. Regenerating replaces proposal.md with the current " <>
          "architecture, discarding any unexecuted edits."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         :ok <- confirmed(params) do
      {:reply, write(scope), frame}
    else
      {:error, reason} -> {:reply, ArchitectureMapper.error(reason), frame}
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
    content = ProposalProjector.project(scope)

    case Environments.write_file(scope.environment, Paths.proposal_path(), content) do
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
    Response.tool()
    |> Response.text(content)
  end
end
