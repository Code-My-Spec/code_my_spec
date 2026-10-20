defmodule CodeMySpec.Qa.Tools.SubmitIssueQaResult do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Qa

  @impl true
  def name, do: "submit_issue_qa_result"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{
      status:
        {:required,
         {:meta, :string,
          [
            description:
              "Outcome: 'pass' (resolves the issue and frees your team), 'partial', or 'fail'"
          ]}},
      task_id:
        {:required,
         {:meta, :string,
          [
            description:
              "Your active qa_complete task id (from the start_task response on this issue)"
          ]}},
      issue_id: {:required, {:meta, :string, [description: "Issue ID being tested"]}},
      scenarios:
        {:required,
         {:meta, {:list, :map},
          [
            description:
              "Structured scenarios: %{name: string, status: 'pass'|'partial'|'fail'|'blocked', observation: string, blocker_issue_id: UUID}. Required fields in each entry: name, status, observation. Use 'blocked' for a check that could not run; blocker_issue_id is required for blocked scenarios and must also appear in issue_ids. An overall pass cannot contain failed or blocked scenarios; submit partial when checks remain blocked."
          ]}},
      issue_ids:
        {:meta, {:list, :string},
         [
           description:
             "Issue ids filed via `create_issue` during this pass. REQUIRED when `status` is `partial` or `fail`. May be empty when `status` is `pass`."
         ]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, owner} <- resolve_owner(scope, context) do
      submit(scope, owner, params, context)
    else
      {:error, reason} -> error_response(reason)
    end
  end

  defp resolve_owner(scope, context) do
    case context[:agent_id] do
      agent_id when is_binary(agent_id) -> Agents.fetch_agent(scope, agent_id)
      _ -> {:error, :no_owner}
    end
  end

  defp submit(scope, owner, params, _context) do
    case Qa.submit_issue_qa_result(scope, owner, params) do
      {:ok, attempt} -> attempt_response(attempt)
      {:error, %Ecto.Changeset{} = changeset} -> validation_error(changeset)
      {:error, reason} -> error_response(reason)
    end
  end

  defp attempt_response(attempt) do
    issue_line =
      case attempt.issue_ids || [] do
        [] -> "issue_ids: (none)"
        ids -> "issue_ids: #{Enum.join(ids, ", ")}"
      end

    {:ok,
     """
     Issue QA attempt submitted.

     attempt_id: #{attempt.id}
     issue:      #{attempt.issue_id}
     status:     #{attempt.status}
     submitted_at: #{attempt.submitted_at}

     Scenarios recorded: #{length(attempt.scenarios)}
     #{issue_line}

     #{satisfaction_note(attempt.status)}
     """}
  end

  defp satisfaction_note(:pass),
    do: "Status pass — the issue is resolved and your team is free of it."

  defp satisfaction_note(status),
    do: "Status #{status} — the issue remains open and bound to your team. Fix and resubmit."

  defp validation_error(changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", safe_to_string(v))
        end)
      end)
      |> Enum.map_join("\n", fn {field, messages} ->
        "  #{field}: #{format_messages(messages)}"
      end)

    {:error, "Invalid submit_issue_qa_result payload:\n#{errors}"}
  end

  # Embedded fields do not come back as a flat list of strings. `scenarios` is
  # an embed, so `traverse_errors` returns one map per entry — and joining that
  # raised `String.Chars not implemented for Map` *inside the error path*. The
  # agent then got "Tool execution crashed", which reads as a broken server, so
  # the reasonable next move is to retry the same payload rather than to add
  # the missing field.
  defp format_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map_join(", ", fn {message, position} -> format_message(message, position) end)
  end

  defp format_messages(message), do: format_message(message, 1)

  defp format_message(message, _position) when is_binary(message), do: message

  # One entry's worth of embed errors. Numbered, because "a scenario is missing
  # its observation" is not actionable when eight were submitted.
  defp format_message(%{} = nested, position) do
    inner =
      Enum.map_join(nested, "; ", fn {field, messages} ->
        "#{field}: #{format_messages(messages)}"
      end)

    "##{position} #{inner}"
  end

  defp format_message(other, _position), do: inspect(other)

  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp error_response(:fail_requires_issue_ids) do
    {:error,
     "Submission rejected: status `fail` or `partial` must carry at least one issue id " <>
       "in `issue_ids`. File every finding via `create_issue` first, then resubmit with " <>
       "the returned ids."}
  end

  defp error_response(:no_owner) do
    {:error, "No agent id on this call, so there is no owner to find the issue QA task on."}
  end

  defp error_response(reason) when is_atom(reason),
    do: {:error, "submit_issue_qa_result failed: #{reason}"}

  defp error_response(reason),
    do: {:error, "submit_issue_qa_result failed: #{inspect(reason)}"}
end
