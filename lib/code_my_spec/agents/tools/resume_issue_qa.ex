defmodule CodeMySpec.Agents.Tools.ResumeIssueQa do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool
  alias CodeMySpec.Agents
  alias CodeMySpec.Qa.IssueQaResumes

  @impl true
  def name, do: "resume_issue_qa"

  @impl true
  def description do
    "Authorize audited QA resumption after an operational partial. Preserves historical attempts; does not certify QA or launch execution."
  end

  @impl true
  def params do
    %{
      reason:
        {:required,
         {:meta, :string,
          [description: "Operational prerequisite and evidence that it is now cleared"]}},
      working_copy_id: {:required, :string},
      issue_id: {:required, :string},
      attempt_id:
        {:required,
         {:meta, :string, [description: "Latest immutable partial QA attempt being resumed"]}},
      coding_agent_id: {:required, :string},
      candidate_sha:
        {:required,
         {:meta, :string,
          [description: "Full preserved candidate SHA independently verified by main"]}},
      coding_task_id:
        {:required, {:meta, :string, [description: "Existing completed fix_issue task"]}},
      operational_only:
        {:required,
         {:meta, :boolean,
          [
            description:
              "Explicit main attestation of operational interruption rather than implementation failure"
          ]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         id when is_binary(id) <- context[:agent_id],
         %{id: ^id} <- Agents.main_agent(scope) do
      response =
        case IssueQaResumes.resume(scope, id, params) do
          {:ok, audit} ->
            {:ok,
             """
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
             """}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      response
    else
      _ ->
        {:error, "Only this project's designated main agent may authorize QA resumption."}
    end
  end
end
