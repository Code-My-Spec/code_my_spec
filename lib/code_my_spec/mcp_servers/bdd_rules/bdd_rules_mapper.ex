defmodule CodeMySpec.McpServers.BddRules.BddRulesMapper do
  @moduledoc """
  Maps BDD Rule data to MCP responses. Text-only responses per project
  convention; identifiers are embedded in the summary so the agent can
  reference them in follow-up calls.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Formatters

  def rule_response(rule) do
    summary = """
    Rule added: "#{rule.statement}" (id: `#{rule.id}`, story_id: `#{rule.story_id}`)

    Next steps:
    - Add at least one scenario via `add_scenario` (kind: `happy_path` for the normal flow; `failure_path` only when a genuine failure surface exists for this rule).
    """

    Response.tool()
    |> Response.text(String.trim(summary))
  end

  def rule_updated_response(rule) do
    summary =
      "Rule updated: \"#{rule.statement}\" (id: `#{rule.id}`, story_id: `#{rule.story_id}`)."

    Response.tool()
    |> Response.text(summary)
  end

  def rule_deleted_response(rule) do
    summary =
      "Rule deleted: \"#{rule.statement}\" (id: `#{rule.id}`, story_id: `#{rule.story_id}`). All linked scenarios were removed by cascade."

    Response.tool()
    |> Response.text(summary)
  end

  def rules_list_response([]) do
    Response.tool()
    |> Response.text("No rules on this story yet. Add one with `add_rule`.")
  end

  def rules_list_response(rules) when is_list(rules) do
    lines =
      Enum.map_join(rules, "\n", fn r ->
        "- (id: `#{r.id}`) #{r.statement}"
      end)

    summary = "Rules on this story (#{length(rules)}):\n\n#{lines}"

    Response.tool()
    |> Response.text(summary)
  end

  def scenario_response(criterion) do
    summary = """
    Scenario added: "#{criterion.description}" (id: `#{criterion.id}`, story_id: `#{criterion.story_id}`, kind: `#{criterion.kind}`)

    Linked to rule_id: `#{criterion.rule_id}`.
    """

    Response.tool()
    |> Response.text(String.trim(summary))
  end

  def scenario_updated_response(criterion) do
    summary =
      "Scenario updated: \"#{criterion.description}\" (id: `#{criterion.id}`, story_id: `#{criterion.story_id}`, kind: `#{criterion.kind}`)."

    Response.tool()
    |> Response.text(summary)
  end

  def question_response(question) do
    summary = """
    Question added: "#{question.text}" (id: `#{question.id}`, status: `#{question.status}`)

    Mark resolved with `resolve_question` once the answer is known.
    """

    Response.tool()
    |> Response.text(String.trim(summary))
  end

  def questions_list_response([]) do
    Response.tool()
    |> Response.text("No questions on this story.")
  end

  def questions_list_response(questions) when is_list(questions) do
    lines =
      Enum.map_join(questions, "\n", fn q ->
        "- (id: `#{q.id}`, status: `#{q.status}`) #{q.text}"
      end)

    summary = "Questions on this story (#{length(questions)}):\n\n#{lines}"

    Response.tool()
    |> Response.text(summary)
  end

  def question_resolved_response(question) do
    Response.tool()
    |> Response.text("Question resolved: id `#{question.id}` is now `#{question.status}`.")
  end

  def validation_error(changeset) do
    Response.tool()
    |> Response.error(Formatters.format_changeset_errors(changeset))
  end

  def error(:persona_linkage_required) do
    Response.tool()
    |> Response.error(
      "Cannot add a rule: this story has no personas linked. Call `add_persona` to create a lightweight persona record (or `link_persona_to_story` for an existing one), then retry."
    )
  end

  def error(:story_not_found) do
    Response.tool()
    |> Response.error("Story not found in the active project.")
  end

  def error(:question_not_found) do
    Response.tool()
    |> Response.error("Question not found in the active account.")
  end

  def error(:rule_not_found) do
    Response.tool()
    |> Response.error(
      "Rule not found on this story. Use `list_rules` to see existing rule statements, or call `add_rule` to create one."
    )
  end

  def error(:criterion_not_found) do
    Response.tool()
    |> Response.error("Scenario not found in the active project.")
  end

  def error(:criterion_verified) do
    Response.tool()
    |> Response.error(
      "Cannot update a verified scenario. Verified criteria are locked and protected from changes."
    )
  end

  def error(:no_attrs) do
    Response.tool()
    |> Response.error("Nothing to update — pass at least one of `title`, `body`, or `kind`.")
  end

  def error(:invalid_kind) do
    Response.tool()
    |> Response.error("Invalid scenario kind. Must be `happy_path` or `failure_path`.")
  end

  def error(:cross_account) do
    Response.tool()
    |> Response.error(
      "Cross-account or cross-project operation rejected. The story does not belong to the active project."
    )
  end

  def error(:missing_active_scope) do
    Response.tool()
    |> Response.error(
      "Active account or project is not set on the scope. Run `init_project` to (re)link the project."
    )
  end

  def error(:no_working_dir) do
    Response.tool()
    |> Response.error(
      "This tool needs the project's working copy, and this request did not name one. " <>
        "The MCP client must send an `X-Harness-Id` header; the id is in .cms_harness.json " <>
        "at the working copy's root, written by `mix cms.harness.onboard`."
    )
  end

  def error(:unauthorized) do
    Response.tool()
    |> Response.error(
      "Scope could not be resolved from the working directory. Confirm the project is initialized."
    )
  end

  def error(error) when is_atom(error) do
    error |> to_string() |> error()
  end

  def error(error) when is_binary(error) do
    Response.tool()
    |> Response.error(error)
  end
end
