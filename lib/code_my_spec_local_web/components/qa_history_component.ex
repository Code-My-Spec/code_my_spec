defmodule CodeMySpecLocalWeb.QaHistoryComponent do
  @moduledoc """
  Renders the QA history chain for a story.

  Each attempt shows its status, agent_id, timestamp, scenarios (with
  observations), linked issue_ids, parent_attempt_id, and any invalidation
  event with its reason. Invalidated attempts are rendered with reduced
  opacity and a badge. Each passed, non-invalidated attempt exposes an
  invalidate button that triggers a server-side event to reveal an inline
  reason form (`data-role='invalidate-reason-form'`).
  """

  use Phoenix.Component

  attr :attempts, :list, required: true, doc: "List of QaAttempt structs (most-recent first)"
  attr :invalidating_attempt_id, :string, default: nil, doc: "Attempt id whose inline form is open"

  def qa_history(assigns) do
    ~H"""
    <div id="qa-history" class="mt-8">
      <h2 class="text-xl font-bold mb-4">QA History</h2>

      <div :if={Enum.empty?(@attempts)} class="text-base-content/60 italic">
        No QA attempts recorded.
      </div>

      <div class="space-y-4">
        <.attempt_card
          :for={attempt <- @attempts}
          attempt={attempt}
          invalidating_attempt_id={@invalidating_attempt_id}
        />
      </div>
    </div>
    """
  end

  attr :attempt, :map, required: true
  attr :invalidating_attempt_id, :string, default: nil

  defp attempt_card(assigns) do
    invalidated? = attempt_invalidated?(assigns.attempt)
    showing_form? = assigns.invalidating_attempt_id == to_string(assigns.attempt.id)
    assigns = assign(assigns, invalidated?: invalidated?, showing_form?: showing_form?)

    ~H"""
    <div
      id={"qa-attempt-#{@attempt.id}"}
      class={[
        "card card-bordered bg-base-100 shadow-sm",
        @invalidated? && "opacity-50"
      ]}
    >
      <div class="card-body p-4">
        <%!-- Header row: status + badges + timestamp --%>
        <div class="flex items-center gap-2 flex-wrap">
          <span class={["badge", status_badge_class(@attempt.status)]}>
            {status_label(@attempt.status)}
          </span>
          <span :if={@invalidated?} class="badge badge-neutral line-through">
            invalidated
          </span>
          <span class="text-xs text-base-content/50 ml-auto">
            {format_dt(@attempt.submitted_at)}
          </span>
        </div>

        <%!-- Agent and parent chain --%>
        <div :if={@attempt.agent_id} class="text-sm text-base-content/70">
          Agent: <code class="text-xs">{@attempt.agent_id}</code>
        </div>
        <div :if={@attempt.parent_attempt_id} class="text-sm text-base-content/50">
          Follows attempt <code class="text-xs">{@attempt.parent_attempt_id}</code>
        </div>

        <%!-- Scenarios --%>
        <div :if={@attempt.scenarios != []} class="mt-2 space-y-1">
          <div class="text-xs font-semibold text-base-content/60 uppercase tracking-wide">
            Scenarios
          </div>
          <div :for={scenario <- @attempt.scenarios} class="text-sm">
            <span class={["badge badge-xs mr-1", scenario_badge_class(scenario.status)]}>
              {status_label(scenario.status)}
            </span>
            <span class="font-medium">{scenario.name}</span>
            <span :if={scenario.observation} class="text-base-content/60 ml-1">
              — {scenario.observation}
            </span>
          </div>
        </div>

        <%!-- Linked issues --%>
        <div :if={@attempt.issue_ids != []} class="mt-2">
          <div class="text-xs font-semibold text-base-content/60 uppercase tracking-wide">
            Issues
          </div>
          <div class="flex flex-wrap gap-1 mt-1">
            <code :for={issue_id <- @attempt.issue_ids} class="badge badge-xs badge-outline">
              {issue_id}
            </code>
          </div>
        </div>

        <%!-- Invalidation reason --%>
        <div :for={inv <- @attempt.invalidations} class="mt-2 p-2 rounded bg-error/10 text-sm">
          <span class="font-semibold text-error">Invalidated</span>
          <span :if={inv.invalidated_at} class="text-xs text-base-content/50 ml-1">
            {format_dt(inv.invalidated_at)}
          </span>
          <p class="mt-1 text-base-content/80">{inv.reason}</p>
        </div>

        <%!-- Invalidate button (only for passed, non-invalidated, no open form) --%>
        <div :if={@attempt.status == :pass && !@invalidated? && !@showing_form?} class="mt-3">
          <button
            type="button"
            class="btn btn-xs btn-outline btn-error"
            data-role="invalidate-qa-attempt"
            data-attempt-id={@attempt.id}
            phx-click="start_invalidate"
            phx-value-attempt_id={@attempt.id}
          >
            Invalidate
          </button>
        </div>

        <%!-- Inline invalidation reason form --%>
        <div :if={@showing_form?} class="mt-3 p-3 border border-error/30 rounded bg-error/5">
          <p class="text-sm font-semibold text-error mb-2">Invalidate QA Attempt</p>
          <form
            phx-submit="invalidate_qa_attempt"
            data-role="invalidate-reason-form"
            class="space-y-3"
          >
            <input type="hidden" name="attempt_id" value={@attempt.id} />
            <div class="fieldset">
              <label>
                <span class="label mb-1">Reason</span>
                <textarea
                  name="reason"
                  class="w-full textarea textarea-bordered"
                  rows="3"
                  placeholder="Describe why this attempt is being invalidated..."
                  required
                ></textarea>
              </label>
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-sm btn-error">
                Invalidate
              </button>
              <button
                type="button"
                class="btn btn-sm"
                phx-click="cancel_invalidate"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp attempt_invalidated?(%{invalidations: invalidations})
       when is_list(invalidations) and invalidations != [],
       do: true

  defp attempt_invalidated?(_), do: false

  defp status_label(:pass), do: "pass"
  defp status_label(:partial), do: "partial"
  defp status_label(:fail), do: "fail"
  defp status_label(other), do: to_string(other)

  defp status_badge_class(:pass), do: "badge-success"
  defp status_badge_class(:partial), do: "badge-warning"
  defp status_badge_class(:fail), do: "badge-error"
  defp status_badge_class(_), do: "badge-neutral"

  defp scenario_badge_class(:pass), do: "badge-success"
  defp scenario_badge_class(:partial), do: "badge-warning"
  defp scenario_badge_class(:fail), do: "badge-error"
  defp scenario_badge_class(_), do: "badge-neutral"

  defp format_dt(nil), do: ""

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_dt(other), do: to_string(other)
end
