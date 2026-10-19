defmodule CodeMySpec.Issues.Tools.CreateIssue do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Agents
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Tools.Responses, as: IssuesMapper
  alias CodeMySpec.Stories.StoryRefs
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.Utils

  @impl true
  def name, do: "create_issue"

  @impl true
  def description do
    """
    Record an issue against the project (`scope: app`) or against
    CodeMySpec itself (`scope: framework`).

    If you encounter undocumented config, a looping hook, a tool error,
    or contradictory prompts inside CodeMySpec, your FIRST call is
    `create_issue` with `scope: framework` — before asking the human
    operator and before working around the problem. The framework is
    the system you are operating inside; friction with it is a
    first-class issue, not a question to escalate or a workaround to
    invent.

    Trigger examples (use `scope: framework`):

    - Confusing or contradictory prompts/instructions
    - Looping stop hooks or stuck workflows
    - Tool or MCP server malfunctions (not an external source returning HTTP 404)
    - Missing, broken, or poorly documented tools
    - Suggestions for improvements to the system

    For project-side bugs and feature gaps (the app under development,
    not CodeMySpec), use `scope: app` (the default).

    Severity must be critical, high, medium, low, or info. `error` and `warning`
    are analyzer finding levels, not issue severities.

    Issues land as `incoming` and are triaged by the human operator. Be
    specific in your description — include the exact error message, what
    you were doing, and what you expected to happen.
    """
  end

  @impl true
  def params do
    %{
      scope:
        {:meta, :string, [description: "Issue scope: app (default), qa, docs, or framework"]},
      description:
        {:required,
         {:meta, :string,
          [
            description:
              "Detailed description of the issue including steps to reproduce if applicable"
          ]}},
      title: {:required, {:meta, :string, [description: "Short issue title"]}},
      severity:
        {:required,
         {:meta, :string, [description: "Issue severity: critical, high, medium, low, or info"]}},
      source_path:
        {:meta, :string, [description: "File path where the issue was found, if applicable"]},
      session_id: {:meta, :string, [description: "Injected by hook — do not set manually"]},
      story_number: {:meta, :integer, [description: "Number of the related story, if applicable"]}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, attrs} <- StoryRefs.put_story_id(scope, build_attrs(params)),
         attrs = default_story(attrs, scope, params, context),
         {:ok, issue} <- create(scope, attrs) do
      IssuesMapper.issue_created_response(issue)
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        IssuesMapper.validation_error(changeset)

      {:error, reason} ->
        IssuesMapper.error(reason)
    end
  end

  # Every scope files where the caller is, framework included.
  #
  # For one day it did not: `7c44ed8d` wrote framework issues into the
  # configured CodeMySpec project, on the reasoning that friction with the
  # framework belongs to the framework. The reasoning is right about *who reads
  # them* and wrong about where they live, and the difference cost a bug a day.
  #
  # Writing across a tenancy boundary meant every read surface needed an
  # exception to match. `get_issue` and `update_issue` did not have one, so an
  # agent could file a framework issue and never read it back or correct it —
  # and `append` exists precisely because reports go stale. Three agents' Vibium
  # evidence arrived as four separate issues for that reason.
  #
  # The deploy-key intake never did this: `FrameworkIssuesController` calls
  # `report_framework_issue(project.account_id, project.id, …)` against the
  # project its own key names. That path predates this one and had it right.
  #
  # So the exception moves to the read, where it is one guarded query rather
  # than a relaxation smeared across create, get and update — and to the safer
  # direction, since a vendor reading issues filed *to* the vendor is milder
  # than a tenant writing into a project it cannot see. See
  # `IssuesRepository.list_framework_issues/1`.
  defp create(scope, attrs), do: Issues.create_issue(scope, attrs)

  # An issue filed from a story's task carries that story unless it names one.
  #
  # 602c92a3 and 129e82f0 were filed by QA from story tasks with no story, so
  # neither gated the story it came from and 129e82f0 reached no triage at all
  # (518f2b52). The submit-time sweep (`Issues.attribute_to_story/3`) only
  # takes issues listed on the attempt; this attributes at filing time.
  #
  # `:app` only (John, 2026-09-30): `:qa`, `:docs` and `:framework` findings
  # are about the tooling around the work and do not gate the story unless
  # given one explicitly. Unlinked `:qa`/`:docs` issues still reach triage
  # through `Issues.list_triageable/2`.
  defp default_story(%{story_id: id} = attrs, _scope, _params, _frame) when not is_nil(id),
    do: attrs

  defp default_story(%{scope: scope} = attrs, _scope, _params, _frame) when scope != :app,
    do: attrs

  defp default_story(attrs, scope, params, context) do
    case caller_story_id(scope, context[:agent_id], Map.get(params, :session_id)) do
      nil -> attrs
      story_id -> Map.put(attrs, :story_id, story_id)
    end
  end

  defp caller_story_id(scope, agent_id, session_id) do
    with {:ok, owner} <- caller(scope, agent_id, session_id),
         %{story_id: story_id} when not is_nil(story_id) <- TaskOwner.active_task(owner),
         {id, ""} <- Integer.parse(to_string(story_id)) do
      id
    else
      _ -> nil
    end
  end

  defp caller(scope, agent_id, session_id), do: Agents.fetch_owner(scope, agent_id, session_id)

  defp build_attrs(params) do
    params
    |> Map.delete(:session_id)
    |> Map.put(:status, :incoming)
    |> maybe_atomize(:severity)
    |> maybe_atomize(:scope)
  end

  defp maybe_atomize(map, key) do
    case Map.get(map, key) do
      val when is_binary(val) -> Map.put(map, key, Utils.safe_to_existing_atom(val, val))
      _ -> map
    end
  end
end
