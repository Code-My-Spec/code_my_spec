defmodule CodeMySpec.McpServers.Qa.Tools.SubmitQaResult do
  @moduledoc """
  Submit a per-story QA outcome.

  Single tool call that ends a QA pass: validates the payload at the
  boundary, writes an immutable attempt row, and surfaces the new
  `attempt_id` for follow-up calls (e.g. `invalidate_qa_attempt`).

  ## Discipline

  Findings flow through `create_issue` during execution — list their
  ids in `issue_ids` so the attempt record links them. There is no
  free-text "findings" field; the absence is intentional. The
  `scenarios` list is the structured record of what you actually
  probed (name + status + observation per scenario).

  Only `status: pass` satisfies the `qa_complete` requirement.
  `partial` and `fail` record an audit row but leave the requirement
  open.

  Non-pass submissions (`fail`, `partial`) **must** carry at least one
  issue id in `issue_ids`. Findings have nowhere else to live; the
  legacy result.md blob is not read by the harness. The tool returns
  an error if you try to submit a non-pass with an empty `issue_ids`
  list.

  Resubmitting on the same `task_id` is allowed and expected — each
  call creates a new attempt; the latest is canonical.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Qa

  schema do
    field :task_id, :string,
      required: true,
      doc: "Active QA task id (from the start_task response on a qa_complete requirement)"

    field :status, :string,
      required: true,
      doc: "Outcome: 'pass' (satisfies qa_complete), 'partial' (audit only), or 'fail' (audit only)"

    field :scenarios, {:list, :map},
      required: true,
      doc:
        "Structured list of scenarios probed during this pass. Each entry: " <>
          "%{name: string, status: 'pass'|'partial'|'fail', observation: string}."

    field :issue_ids, {:list, :string},
      doc: "Optional list of issue ids filed via `create_issue` during this QA pass"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         attrs <- build_attrs(params),
         {:ok, attempt} <- Qa.submit_qa_result(scope, attrs) do
      {:reply, attempt_response(attempt), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, error_response(reason), frame}
    end
  end

  # Pass params straight through to the changeset.
  #
  # `Ecto.Enum` on `:status` casts the string ("pass"/"partial"/"fail")
  # into the matching atom. Embedded `Scenario.changeset/2` accepts each
  # scenario map's native keys. The previous version added an atom
  # `:status` key onto string-keyed scenario maps, producing a
  # mixed-key map that crashed `Ecto.Changeset.cast/3`.
  defp build_attrs(params), do: params

  defp attempt_response(attempt) do
    issue_ids = attempt.issue_ids || []

    issue_line =
      case issue_ids do
        [] -> "issue_ids: (none)"
        ids -> "issue_ids: #{Enum.join(ids, ", ")}"
      end

    Response.text(
      Response.tool(),
      """
      QA attempt submitted.

      attempt_id: #{attempt.id}
      story_id:   #{attempt.story_id}
      status:     #{attempt.status}
      parent_attempt_id: #{attempt.parent_attempt_id || "none (first attempt)"}
      submitted_at: #{attempt.submitted_at}

      Scenarios recorded: #{length(attempt.scenarios)}
      #{issue_line}

      #{satisfaction_note(attempt.status)}
      """
    )
  end

  defp satisfaction_note(:pass),
    do: "Status pass — qa_complete is satisfied for the story."

  defp satisfaction_note(status),
    do: "Status #{status} — qa_complete remains unsatisfied. Resubmit when ready."

  defp validation_error(changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", safe_to_string(v))
        end)
      end)
      |> Enum.map_join("\n", fn {field, messages} ->
        "  #{field}: #{Enum.join(messages, ", ")}"
      end)

    Response.error(Response.tool(), "Invalid submit_qa_result payload:\n#{errors}")
  end

  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp error_response(:fail_requires_issue_ids) do
    Response.error(
      Response.tool(),
      """
      Submission rejected: status `fail` or `partial` must carry at least one issue id in `issue_ids`.

      File every finding via `create_issue` first, then resubmit with the returned ids.
      A non-pass result with an empty `issue_ids` list is dead work — the failure
      disappears the moment your session ends. There is no other place for findings
      to live; the legacy result.md text blob is no longer read by the harness.

      If you genuinely found nothing wrong, submit with `status: "pass"` instead.
      """
    )
  end

  defp error_response(reason) when is_atom(reason),
    do: Response.error(Response.tool(), "submit_qa_result failed: #{reason}")

  defp error_response(reason),
    do: Response.error(Response.tool(), "submit_qa_result failed: #{inspect(reason)}")
end
