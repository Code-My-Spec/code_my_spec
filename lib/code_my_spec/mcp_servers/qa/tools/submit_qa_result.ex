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
  alias CodeMySpec.Qa.EvidenceUpload
  alias CodeMySpec.Qa.QaAttempts
  alias CodeMySpec.Stories

  schema do
    field :task_id, :string,
      required: true,
      doc: "Active QA task id (from the start_task response on a qa_complete requirement)"

    field :status, :string,
      required: true,
      doc:
        "Outcome: 'pass' (satisfies qa_complete), 'partial' (audit only), or 'fail' (audit only)"

    field :scenarios, {:list, :map},
      required: true,
      doc:
        "Structured list of scenarios probed during this pass. Each entry: " <>
          "%{name: string, status: 'pass'|'partial'|'fail', observation: string}."

    field :issue_ids, {:list, :string},
      doc:
        "List of issue ids filed via `create_issue` during this QA pass. " <>
          "REQUIRED when `status` is `partial` or `fail` — submissions with a non-pass " <>
          "status and an empty `issue_ids` list are rejected at the tool boundary. " <>
          "May be empty when `status` is `pass`."

    field :tools_used, {:list, :string},
      doc:
        "Which tools you actually called while gathering this evidence — e.g. " <>
          "['browser_navigate', 'browser_click', 'browser_get_text']. Self-reported " <>
          "and not independently checked, same as the scenario observations beside " <>
          "it: this exists so 'did this pass drive a browser' is a query afterward " <>
          "instead of an inference from adjectives. Report what you called, not what " <>
          "the story required — an empty list on a browser-required story is itself " <>
          "the finding, not something to round up."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame, params) do
      {:ok, scope} -> submit(scope, params, frame)
      {:error, reason} -> {:reply, error_response(reason), frame}
    end
  end

  defp submit(scope, params, frame) do
    case Qa.submit_qa_result(scope, build_attrs(params)) do
      {:ok, attempt} ->
        story_number = story_number(scope, attempt.story_id)
        attempt = upload_evidence(scope, frame, attempt, story_number)

        {:reply, attempt_response(attempt, story_number), frame}

      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, validation_error(changeset), frame}

      {:error, {:task_not_found, open}} ->
        {:reply, error_response(task_not_found_message(scope, open)), frame}

      {:error, reason} ->
        {:reply, error_response(reason), frame}
    end
  end

  defp story_number(_scope, nil), do: nil

  defp story_number(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> nil
      story -> story.number
    end
  end

  # Names the id it wanted.
  #
  # `task_not_found` alone sent a QA agent looking for a cause that was not
  # there: it had passed story 1000's id as the task id, was refused, and
  # reported "the task session is unavailable" — a diagnosis it could not act on
  # and that was not true. The id it needed was already open on its own agent.
  defp task_not_found_message(_scope, []) do
    "No task with that id, and no QA task is open in this working copy. " <>
      "`start_task` on a `qa_complete` requirement opens one and returns its id."
  end

  defp task_not_found_message(scope, open) do
    numbers = Stories.story_numbers(scope)

    listed =
      Enum.map_join(open, "\n", fn {id, story_id} ->
        "  task_id #{inspect(id)} — story #{Map.get(numbers, story_id, "?")}"
      end)

    "No task with that id. `task_id` is the task's own id, not a story number — " <>
      "these QA tasks are open here:\n\n" <> listed
  end

  # Asked only on a pass, and asked after the attempt is written.
  #
  # Only on a pass because that is the claim: `partial` and `fail` record an
  # audit row and leave `qa_complete` open, so there is nothing outliving its
  # evidence.
  #
  # After rather than before, same reasoning as the git-era check this
  # replaced: refusing to *write the attempt* would lose the QA work — the
  # agent has finished probing, and the attempt row is the only place that
  # record exists. So the row lands first, and uploading evidence is a
  # second write onto a row that already exists rather than a condition on
  # whether it gets written at all — `EvidenceUpload.collect/4` and
  # `QaAttempts.attach_evidence/2` are both best-effort for exactly this
  # reason (criterion 1847's local-dev case: no S3 bucket configured
  # records "not uploaded" and does not fail the submission).
  defp upload_evidence(scope, frame, %{status: :pass} = attempt, story_number)
       when not is_nil(story_number) do
    env = Validators.mcp_environment(frame)

    case EvidenceUpload.collect(env, scope.active_project_id, attempt.id, story_number) do
      [] -> attempt
      evidence -> QaAttempts.attach_evidence(attempt, evidence)
    end
  end

  defp upload_evidence(_scope, _frame, attempt, _story_number), do: attempt

  # Pass params straight through to the changeset.
  #
  # `Ecto.Enum` on `:status` casts the string ("pass"/"partial"/"fail")
  # into the matching atom. Embedded `Scenario.changeset/2` accepts each
  # scenario map's native keys. The previous version added an atom
  # `:status` key onto string-keyed scenario maps, producing a
  # mixed-key map that crashed `Ecto.Changeset.cast/3`.
  defp build_attrs(params), do: params

  defp attempt_response(attempt, story_number) do
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
      story:      #{story_number}
      status:     #{attempt.status}
      parent_attempt_id: #{attempt.parent_attempt_id || "none (first attempt)"}
      submitted_at: #{attempt.submitted_at}

      Scenarios recorded: #{length(attempt.scenarios)}
      #{issue_line}
      #{tools_used_line(attempt.tools_used)}
      #{evidence_line(attempt.evidence)}

      #{satisfaction_note(attempt.status)}#{wait_note(attempt.wait)}
      """
    )
  end

  defp wait_note({:issue, id}),
    do: "\n\nYour task is blocked on issue #{id}; resolving it hands the story back to you."

  # Refused, not silent: a block below the fix threshold never releases.
  defp wait_note({:not_blocking, threshold, issues}) do
    named =
      case issues do
        [] -> "none of the ids name an issue in this project"
        _ -> Enum.map_join(issues, ", ", &"#{&1.id} (#{&1.severity}, #{&1.status})")
      end

    "\n\nNot blocked: no named issue is open at or above the project's fix threshold " <>
      "(#{threshold}), so none will be fixed before QA. Recorded: #{named}. " <>
      "Your task stays active — finish the attempt: resubmit `pass` if nothing at " <>
      "#{threshold}+ is wrong, or file that finding and resubmit `fail` with it."
  end

  defp wait_note(_), do: ""

  defp tools_used_line(nil), do: "tools_used: (not reported)"
  defp tools_used_line([]), do: "tools_used: (none — reported explicitly)"
  defp tools_used_line(tools), do: "tools_used: #{Enum.join(tools, ", ")}"

  defp evidence_line(nil), do: "evidence: (none uploaded)"
  defp evidence_line([]), do: "evidence: (none uploaded)"

  defp evidence_line(evidence),
    do: "evidence: #{length(evidence)} file(s) uploaded — " <> Enum.map_join(evidence, ", ", & &1.name)

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
        "  #{field}: #{format_messages(messages)}"
      end)

    Response.error(Response.tool(), "Invalid submit_qa_result payload:\n#{errors}")
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
