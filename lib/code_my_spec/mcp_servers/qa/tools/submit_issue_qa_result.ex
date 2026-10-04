defmodule CodeMySpec.McpServers.Qa.Tools.SubmitIssueQaResult do
  @moduledoc """
  Submit a QA outcome for an issue (story 1091).

  Single tool call that ends an issue QA pass: writes an immutable attempt
  row, and on `status: pass` resolves the issue and frees the team bound to
  it. The agent calling this is the one testing the issue — it travels on
  the connection, same as `start_task` and `evaluate_task`.

  Non-pass submissions (`fail`, `partial`) **must** carry at least one issue
  id in `issue_ids`, filed via `create_issue` during the pass — same
  discipline as `submit_qa_result`'s story contract. A non-pass leaves the
  issue open and bound; the coder is offered it again.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Qa

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID being tested"

    field :task_id, :string,
      required: true,
      doc: "Your active qa_complete task id (from the start_task response on this issue)"

    field :status, :string,
      required: true,
      doc: "Outcome: 'pass' (resolves the issue and frees your team), 'partial', or 'fail'"

    field :scenarios, {:list, :map},
      required: true,
      doc:
        "Structured list of scenarios probed. Each entry: " <>
          "%{name: string, status: 'pass'|'partial'|'fail', observation: string}."

    field :issue_ids, {:list, :string},
      doc:
        "Issue ids filed via `create_issue` during this pass. REQUIRED when `status` " <>
          "is `partial` or `fail`. May be empty when `status` is `pass`."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, owner} <- resolve_owner(scope, frame) do
      submit(scope, owner, params, frame)
    else
      {:error, reason} -> {:reply, error_response(reason), frame}
    end
  end

  defp resolve_owner(scope, frame) do
    case frame.assigns[:agent_id] do
      agent_id when is_binary(agent_id) -> Agents.fetch_agent(scope, agent_id)
      _ -> {:error, :no_owner}
    end
  end

  defp submit(scope, owner, params, frame) do
    case Qa.submit_issue_qa_result(scope, owner, params) do
      {:ok, attempt} -> {:reply, attempt_response(attempt), frame}
      {:error, %Ecto.Changeset{} = changeset} -> {:reply, validation_error(changeset), frame}
      {:error, reason} -> {:reply, error_response(reason), frame}
    end
  end

  defp attempt_response(attempt) do
    issue_line =
      case attempt.issue_ids || [] do
        [] -> "issue_ids: (none)"
        ids -> "issue_ids: #{Enum.join(ids, ", ")}"
      end

    Response.text(Response.tool(), """
    Issue QA attempt submitted.

    attempt_id: #{attempt.id}
    issue:      #{attempt.issue_id}
    status:     #{attempt.status}
    submitted_at: #{attempt.submitted_at}

    Scenarios recorded: #{length(attempt.scenarios)}
    #{issue_line}

    #{satisfaction_note(attempt.status)}
    """)
  end

  defp satisfaction_note(:pass),
    do: "Status pass — the issue is resolved and your team is free of it."

  defp satisfaction_note(status),
    do: "Status #{status} — the issue remains open and bound to your team. Fix and resubmit."

  defp validation_error(changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)
      |> Enum.map_join("\n", fn {field, messages} -> "  #{field}: #{Enum.join(List.wrap(messages), ", ")}" end)

    Response.error(Response.tool(), "Invalid submit_issue_qa_result payload:\n#{errors}")
  end

  defp error_response(:fail_requires_issue_ids) do
    Response.error(
      Response.tool(),
      "Submission rejected: status `fail` or `partial` must carry at least one issue id " <>
        "in `issue_ids`. File every finding via `create_issue` first, then resubmit with " <>
        "the returned ids."
    )
  end

  defp error_response(:no_owner) do
    Response.error(
      Response.tool(),
      "No agent id on this call, so there is no owner to find the issue QA task on."
    )
  end

  defp error_response(reason) when is_atom(reason),
    do: Response.error(Response.tool(), "submit_issue_qa_result failed: #{reason}")

  defp error_response(reason),
    do: Response.error(Response.tool(), "submit_issue_qa_result failed: #{inspect(reason)}")
end
