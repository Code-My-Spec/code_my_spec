defmodule CodeMySpec.McpServers.MainAgent.Tools.ResumeIssueQa do
  @moduledoc "Authorize audited QA resumption after an operational partial. Preserves historical attempts; does not certify QA or launch execution."
  use Anubis.Server.Component, type: :tool
  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Qa.IssueQaResumes

  schema do
    field(:issue_id, :string, required: true)

    field(:attempt_id, :string,
      required: true,
      doc: "Latest immutable partial QA attempt being resumed"
    )

    field(:working_copy_id, :string, required: true)
    field(:coding_agent_id, :string, required: true)
    field(:coding_task_id, :string, required: true, doc: "Existing completed fix_issue task")

    field(:candidate_sha, :string,
      required: true,
      doc: "Full preserved candidate SHA independently verified by main"
    )

    field(:reason, :string,
      required: true,
      doc: "Operational prerequisite and evidence that it is now cleared"
    )

    field(:operational_only, :boolean,
      required: true,
      doc:
        "Explicit main attestation of operational interruption rather than implementation failure"
    )
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         id when is_binary(id) <- frame.assigns[:agent_id],
         %{id: ^id} <- Agents.main_agent(scope) do
      response =
        case IssueQaResumes.resume(scope, id, params) do
          {:ok, audit} ->
            Response.tool()
            |> Response.text("""
            QA resumption authorized.
            Audit: #{audit.id}
            Issue: #{audit.issue_id}
            Original partial: #{audit.attempt_id}
            Copy: #{audit.working_copy_id}
            Candidate: #{audit.candidate_sha}
            Historical attempts and the completed coding task remain unchanged.
            QA must independently verify this candidate through
            start_task(requirement_name: "qa_complete", entity_type: "issue", entity_id: "#{audit.issue_id}").
            This transition does not authorize execution, certify QA or promote work.
            """)

          {:error, reason} ->
            Response.tool() |> Response.error(inspect(reason))
        end

      {:reply, response, frame}
    else
      _ ->
        {:reply,
         Response.tool()
         |> Response.error(
           "Only this project's designated main agent may authorize QA resumption."
         ), frame}
    end
  end
end
