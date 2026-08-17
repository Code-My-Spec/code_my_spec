defmodule CodeMySpecSpex.Story727.Criterion6459Spex do
  @moduledoc """
  Story 727 — Engineer trusts QA pass claims as audit-grade events
  Criterion 6459 — Story page renders the QA history chain.

  Demonstrates the engineer-in-a-browser surface: the local app's
  story page renders the QA history for that story, showing each
  attempt's status, agent, timestamp, scenarios, and any
  invalidation event with its reason.

  Surfaces:
  - `CodeMySpec.McpServers.Qa.Tools.SubmitQaResult` (seed history)
  - `CodeMySpec.McpServers.Qa.Tools.InvalidateQaAttempt` (seed
    invalidation event)
  - `CodeMySpecLocalWeb.StoryLive` at
    `/projects/:project_name/stories/:id` (the render surface)
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Qa.Tools.{InvalidateQaAttempt, SubmitQaResult}

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :setup_qa_story_task

  spex "The story page renders the full QA history chain" do
    scenario "Story page renders the QA history chain" do
      given_ "three QA attempts on the story, one invalidated", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        attempt_ids =
          for marker <- ["alpha", "beta", "gamma"] do
            {:reply, response, _frame} =
              SubmitQaResult.execute(
                %{
                  task_id: context.task_id,
                  status: "pass",
                  scenarios: [%{name: marker, status: "pass", observation: marker}],
                  issue_ids: []
                },
                frame
              )

            refute response.isError
            extract_attempt_id!(response_text(response))
          end

        [_, middle_id, _] = attempt_ids

        {:reply, _invalidate, _frame} =
          InvalidateQaAttempt.execute(
            %{attempt_id: middle_id, reason: "Test probe was incomplete"},
            frame
          )

        {:ok, Map.put(context, :attempt_ids, attempt_ids)}
      end

      when_ "the engineer navigates to the local story page", context do
        {:ok, view, html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories/#{context.story.id}")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the QA history section renders all three attempts in order", context do
        # Position, not presence. "In order" is the claim and only presence was
        # checked — three attempts rendered newest-last would have passed. The
        # markers were also the wrong thing to read: they are scenario names,
        # which the page prints twice per card. The cards carry the attempt id.
        [alpha, beta, gamma] = context.attempt_ids
        positions = Enum.map([gamma, beta, alpha], &card_position!(context.html, &1))

        assert positions == Enum.sort(positions),
               "expected the newest attempt first, got card positions " <>
                 "#{inspect(Enum.zip([:gamma, :beta, :alpha], positions))}"

        {:ok, context}
      end

      and_ "the invalidated attempt shows its invalidation reason", context do
        assert context.html =~ "Test probe was incomplete",
               "expected invalidation reason in rendered html"

        assert context.html =~ ~r/invalidated/i,
               "expected the invalidated attempt to be visually marked"

        {:ok, context}
      end

      and_ "each attempt shows status, scenarios, and timestamp markers", context do
        # Per card, because "each attempt shows" is the claim and one match
        # anywhere on the page satisfied it — two cards could have rendered no
        # status at all. `~r/pass/i` was also loose enough to be met by the
        # word "password", and a bare `\d{4}-\d{2}-\d{2}` by any date the
        # layout happens to print.
        for attempt_id <- context.attempt_ids do
          assert has_element?(context.view, "#qa-attempt-#{attempt_id} .badge", "pass"),
                 "expected attempt #{attempt_id} to render its status"

          assert has_element?(
                   context.view,
                   "#qa-attempt-#{attempt_id}",
                   ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/
                 ),
                 "expected attempt #{attempt_id} to render its submitted-at timestamp"
        end

        {:ok, context}
      end
    end
  end

  # Where an attempt's card starts in the document. `desc: inserted_at,
  # desc: id` orders the list, so ties are broken and the order is a fact
  # about the page rather than a race.
  defp card_position!(html, attempt_id) do
    html
    |> :binary.match("qa-attempt-#{attempt_id}")
    |> position!(attempt_id, html)
  end

  defp position!({start, _length}, _attempt_id, _html), do: start

  defp position!(:nomatch, attempt_id, html),
    do: raise("expected a card for attempt #{attempt_id}, got: #{html}")
end
