defmodule CodeMySpec.McpServers.Qa.Tools.ListQaAttempts do
  @moduledoc """
  List the QA attempt history for a story.

  Returns every attempt on the story, most-recent first. Each entry
  carries the audit-grade fields: status, agent_id, scenarios (with
  observations), linked issue_ids, parent_attempt_id (the chain
  back), submitted_at, and any invalidation event with its reason
  and the engineer who issued it.

  Use this to:

  - Review prior QA on a story before redoing it
  - Audit who invalidated a pass and why
  - Walk the chain of attempts after one or more invalidations
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Qa

  schema do
    field :story_id, :integer,
      required: true,
      doc: "Story id whose QA history you want to read"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         attempts <- Qa.list_qa_attempts(scope, params.story_id) do
      {:reply, attempts_response(params.story_id, attempts), frame}
    else
      {:error, reason} ->
        {:reply, error_response(reason), frame}
    end
  end

  defp attempts_response(story_id, []) do
    Response.text(
      Response.tool(),
      "No QA attempts recorded for story #{story_id}."
    )
  end

  defp attempts_response(story_id, attempts) do
    body = Enum.map_join(attempts, "\n\n---\n\n", &render_attempt/1)

    Response.text(
      Response.tool(),
      """
      QA history for story #{story_id} (#{length(attempts)} attempt#{if length(attempts) == 1, do: "", else: "s"}, most-recent first):

      #{body}
      """
    )
  end

  defp render_attempt(attempt) do
    invalidation = render_invalidation(attempt)

    """
    attempt_id: #{attempt.id}
    status:     #{attempt.status}
    agent_id:   #{attempt.agent_id || "(unknown)"}
    submitted_at: #{attempt.submitted_at}
    parent_attempt_id: #{attempt.parent_attempt_id || "none"}
    scenarios (#{length(attempt.scenarios)}):
    #{render_scenarios(attempt.scenarios)}
    issue_ids: #{render_issue_ids(attempt.issue_ids)}#{invalidation}
    """
    |> String.trim_trailing()
  end

  defp render_scenarios([]), do: "  (none)"

  defp render_scenarios(scenarios) do
    Enum.map_join(scenarios, "\n", fn s ->
      "  - #{s.name} [#{s.status}] — #{s.observation}"
    end)
  end

  defp render_issue_ids(nil), do: "(none)"
  defp render_issue_ids([]), do: "(none)"
  defp render_issue_ids(ids), do: Enum.join(ids, ", ")

  defp render_invalidation(%{invalidations: invalidations})
       when is_list(invalidations) and invalidations != [] do
    Enum.map_join(invalidations, "", fn inv ->
      "\ninvalidated at #{inv.invalidated_at} by user #{inv.invalidated_by_user_id}\n  reason: #{inv.reason}"
    end)
  end

  defp render_invalidation(_), do: ""

  defp error_response(reason) when is_atom(reason),
    do: Response.error(Response.tool(), "list_qa_attempts failed: #{reason}")

  defp error_response(reason),
    do: Response.error(Response.tool(), "list_qa_attempts failed: #{inspect(reason)}")
end
