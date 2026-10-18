defmodule CodeMySpec.BddRules.Tools.Responses do
  @moduledoc """
  Maps BDD Rule data to MCP responses. Text-only responses per project
  convention; identifiers are embedded in the summary so the agent can
  reference them in follow-up calls.
  """

  def rule_response(rule) do
    summary = """
    Rule added: "#{rule.statement}" (id: `#{rule.id}`)

    Next steps:
    - Add at least one scenario via `add_scenario` (kind: `happy_path` for the normal flow; `failure_path` only when a genuine failure surface exists for this rule).
    """

    {:ok, String.trim(summary)}
  end

  def rule_updated_response(rule) do
    summary =
      "Rule updated: \"#{rule.statement}\" (id: `#{rule.id}`)."

    {:ok, summary}
  end

  def rule_deleted_response(rule) do
    summary =
      "Rule deleted: \"#{rule.statement}\" (id: `#{rule.id}`). All linked scenarios were retired with it."

    {:ok, summary}
  end

  def rules_list_response([]) do
    {:ok, "No rules on this story yet. Add one with `add_rule`."}
  end

  def rules_list_response(rules) when is_list(rules) do
    lines =
      Enum.map_join(rules, "\n", fn r ->
        "- (id: `#{r.id}`) #{r.statement}"
      end)

    summary = "Rules on this story (#{length(rules)}):\n\n#{lines}"

    {:ok, summary}
  end

  def scenario_response(criterion) do
    summary = """
    Scenario added: "#{criterion.description}" (criterion #{criterion.number}, kind: `#{criterion.kind}`)

    Linked to rule_id: `#{criterion.rule_id}`.
    """

    {:ok, String.trim(summary)}
  end

  def scenario_updated_response(criterion) do
    summary =
      "Scenario updated: \"#{criterion.description}\" (criterion #{criterion.number}, kind: `#{criterion.kind}`)."

    {:ok, summary}
  end

  def question_response(question) do
    summary = """
    Question added: "#{question.text}" (id: `#{question.id}`, status: `#{question.status}`)

    Mark resolved with `resolve_question` once the answer is known.
    """

    {:ok, String.trim(summary)}
  end

  def questions_list_response([]) do
    {:ok, "No questions on this story."}
  end

  def questions_list_response(questions) when is_list(questions) do
    lines =
      Enum.map_join(questions, "\n", fn q ->
        "- (id: `#{q.id}`, status: `#{q.status}`) #{q.text}#{resolution_suffix(q)}"
      end)

    summary = "Questions on this story (#{length(questions)}):\n\n#{lines}"

    {:ok, summary}
  end

  def question_resolved_response(question) do
    {:ok,
     "Question resolved: id `#{question.id}` is now `#{question.status}`.#{resolution_line(question)}"}
  end

  defp resolution_suffix(%{resolution: resolution})
       when is_binary(resolution) and resolution != "",
       do: " — #{resolution}"

  defp resolution_suffix(_question), do: ""

  defp resolution_line(%{resolution: resolution}) when is_binary(resolution) and resolution != "",
    do: " Answer: #{resolution}"

  defp resolution_line(_question), do: ""

  def validation_error(changeset) do
    {:error, CodeMySpec.Tools.changeset_errors(changeset)}
  end

  def error(:persona_linkage_required) do
    {:error,
     "Cannot add a rule: this story has no personas linked. Call `create_persona` to create a lightweight persona record (or `link_persona_to_story` for an existing one), then retry."}
  end

  def error(:story_not_found) do
    {:error, "Story not found in the active project."}
  end

  def error(:question_not_found) do
    {:error,
     "Question not found in the active account. This resolves a Three Amigos " <>
       "question raised on a story — ids come from list_questions on that story, " <>
       "not from list_open_questions. An id from list_open_questions is a different " <>
       "record; use answer_question or escalate_question for those instead."}
  end

  def error(:rule_not_found) do
    {:error,
     "Rule not found on this story. Use `list_rules` to see existing rule statements, or call `add_rule` to create one."}
  end

  def error(:criterion_not_found) do
    {:error, "Scenario not found in the active project."}
  end

  def error(:criterion_verified) do
    {:error,
     "Cannot update a verified scenario. Verified criteria are locked and protected from changes."}
  end

  def error({:criteria_verified_or_specced, descriptions}) do
    list = Enum.map_join(descriptions, "\n", &"  - #{&1}")

    {:error,
     "Cannot delete this rule: #{length(descriptions)} of its scenario(s) are verified " <>
       "or already have a spec file written for them, and deleting the rule would delete " <>
       "them with it — orphaning any spec file already claimed by one, unclaimable by " <>
       "anything afterward.\n\n#{list}\n\n" <>
       "If the rule is genuinely superseded, resolve or remove the spec files for these " <>
       "scenarios first (or unverify them), then delete the rule. `retire_criterion` still " <>
       "refuses a verified one individually for the same reason."}
  end

  def error(:no_attrs) do
    {:error, "Nothing to update — pass at least one of `title`, `body`, or `kind`."}
  end

  def error(:invalid_kind) do
    {:error, "Invalid scenario kind. Must be `happy_path` or `failure_path`."}
  end

  def error(:cross_account) do
    {:error,
     "Cross-account or cross-project operation rejected. The story does not belong to the active project."}
  end

  def error(:missing_active_scope) do
    {:error,
     "Active account or project is not set on the scope. Run `init_project` to (re)link the project."}
  end

  def error(:no_working_dir) do
    {:error,
     "This tool needs the project's working copy, and this request did not name one. " <>
       "The MCP client must send an `X-Harness-Id` header; the id is in .cms_harness.json " <>
       "at the working copy's root, written by `mix cms.harness.onboard`."}
  end

  def error(:unauthorized) do
    {:error,
     "Scope could not be resolved from the working directory. Confirm the project is initialized."}
  end

  def error(error) when is_atom(error) do
    error |> to_string() |> error()
  end

  def error(error) when is_binary(error) do
    {:error, error}
  end
end
