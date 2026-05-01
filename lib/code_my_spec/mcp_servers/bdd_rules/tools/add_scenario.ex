defmodule CodeMySpec.McpServers.BddRules.Tools.AddScenario do
  @moduledoc """
  Adds a Scenario (green card) to a story during a Three Amigos session.

  Each scenario is a Criterion record carrying both the title (one-line
  description in domain terms) and the Given/When/Then body (plain
  Gherkin), linked to a Rule via `rule_id`. Rules and scenarios are
  created together as a single atom — there is no two-stage "title now,
  body later" split.

  The scenario's `kind` distinguishes happy-path from failure-path
  coverage. `kind` is metadata for UI grouping and Gherkin rendering;
  the readiness gate only requires ≥1 scenario per rule of any kind.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddRules
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :story_id, :integer, required: true, doc: "ID of the story to add the scenario to."

    field :rule_statement, :string,
      required: true,
      doc:
        "The exact statement of the Rule this scenario illustrates. The Rule must already exist on the story."

    field :title, :string,
      required: true,
      doc:
        "Scenario title (one-line, in domain language; names the persona with relevant context)."

    field :kind, :string,
      required: true,
      doc: "`happy_path` or `failure_path`. Use `happy_path` for the normal flow; add `failure_path` only when a genuine failure surface exists for this rule."

    field :body, :string,
      required: true,
      doc: "Plain-text Gherkin Given/When/Then body for the scenario."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         story_id <- get_param(params, :story_id),
         {:ok, story} <- find_story(scope, story_id),
         {:ok, rule} <-
           find_rule_by_statement(scope, story_id, get_param(params, :rule_statement)),
         {:ok, kind} <- parse_kind(get_param(params, :kind)),
         {:ok, criterion} <-
           AcceptanceCriteria.create_criterion(scope, story, %{
             description: get_param(params, :title),
             body: get_param(params, :body),
             kind: kind,
             rule_id: rule.id
           }) do
      {:reply, BddRulesMapper.scenario_response(criterion), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, BddRulesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, BddRulesMapper.error(reason), frame}
    end
  end

  defp find_story(scope, story_id) do
    case Stories.get_story(scope, story_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp find_rule_by_statement(scope, story_id, statement) do
    rules = BddRules.list_rules_for_story(scope, story_id)

    case Enum.find(rules, &(&1.statement == statement)) do
      nil -> {:error, :rule_not_found}
      rule -> {:ok, rule}
    end
  end

  defp parse_kind("happy_path"), do: {:ok, :happy_path}
  defp parse_kind("failure_path"), do: {:ok, :failure_path}
  defp parse_kind(_), do: {:error, :invalid_kind}

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
