defmodule CodeMySpecWeb.AgentPerformanceLive.IndexTest do
  use CodeMySpecSpex.Case, async: true

  import CodeMySpecSpex.AgentPerformanceHelpers

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "a stage with no matching tasks shows as unknown, not as zero", context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted with an unmapped task",
        description: "A finished story whose only task does not belong to any named stage."
      })

    {:ok, story} = story |> Story.changeset(%{ready_for_dev: true}) |> Repo.update()

    agent = Fixtures.running_agent(context.scope, role: "coding")
    :ok = Agents.claim_story(context.scope, agent, story.id)

    Fixtures.agent_task_fixture(context.scope, agent,
      story_id: story.id,
      session_type: CodeMySpec.AgentTasks.ResearchTopic,
      started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    )

    {:ok, story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: DateTime.utc_now()})
      |> Repo.update()

    {:ok, index, _html} = live(context.conn, index_path(context))
    html = render_async(index)

    assert html =~ story.title

    row = index |> chart_data("[data-test='story-stages-chart']") |> story_row(story.title)

    refute "Total: unknown" in row.details,
           "the story's own total release-to-promotion time could not be computed"

    assert row.hours["specs"] == nil,
           "a stage with no matching tasks is shown as though no time at all was spent on it"

    assert Enum.any?(row.details, &(&1 =~ "Unknown" and &1 =~ "specs")),
           "a stage with no matching tasks is not shown as unknown"
  end

  test "the time-per-story chart notes that stages can overlap and may exceed the total",
       context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Promoted with a single task",
        description: "Enough for a cycle-time card to render."
      })

    {:ok, story} = story |> Story.changeset(%{ready_for_dev: true}) |> Repo.update()

    agent = Fixtures.running_agent(context.scope, role: "coding")
    :ok = Agents.claim_story(context.scope, agent, story.id)

    Fixtures.agent_task_fixture(context.scope, agent,
      story_id: story.id,
      session_type: CodeMySpec.AgentTasks.ComponentCode,
      started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    )

    {:ok, _story} =
      story
      |> Story.changeset(%{promoted_version: "0.1.0", promoted_at: DateTime.utc_now()})
      |> Repo.update()

    {:ok, index, _html} = live(context.conn, index_path(context))
    _html = render_async(index)

    stages = index |> element("[data-test='story-stages']") |> render()

    assert stages =~ "Stages can overlap",
           "the time-per-story chart does not say that stages can overlap and may exceed the total"
  end

  test "offer health narrows its ring to one role, read in the background", context do
    coder = Fixtures.running_agent(context.scope, role: "coding")
    qa = Fixtures.running_agent(context.scope, role: "qa")
    Offers.record(nil, coder, :work, {"requirement", "coder-offer"})
    Offers.record(nil, qa, :work, {"requirement", "qa-offer-1"})
    Offers.record(nil, qa, :work, {"requirement", "qa-offer-2"})

    {:ok, index, _html} = live(context.conn, index_path(context))
    _ = render_async(index)

    assert has_element?(
             index,
             "#offer-results-performance-all[aria-label='Offer results: Open: 3']"
           )

    changed =
      index |> element("[data-test='offer-role-filter']") |> render_change(%{"role" => "qa"})

    assert changed =~ "offer-results-loading",
           "the role's offers were read before the page answered the change"

    _ = render_async(index)

    assert has_element?(
             index,
             "#offer-results-performance-qa[aria-label='Offer results: Open: 2']"
           )

    assert has_element?(index, "[data-test='offer-health-role'][data-role='qa']")
    refute has_element?(index, "[data-test='offer-health-role'][data-role='coding']")
  end

  test "the page leads with the week's rates, and a bad one gets its change first", context do
    coder = Fixtures.running_agent(context.scope, role: "coding")
    now = DateTime.utc_now()

    for status <- ["expired", "expired", "approved"] do
      Repo.insert!(%CodeMySpec.Notifications.PermissionRequest{
        user_id: context.user.id,
        agent_id: coder.id,
        tool_name: "tap_out",
        tool_input: %{"reason" => "blocked"},
        status: status,
        inserted_at: now,
        updated_at: now
      })
    end

    {:ok, index, _html} = live(context.conn, index_path(context))
    _ = render_async(index)

    assert index |> element("[data-test='standouts']") |> render() =~ "Tap-outs expired undecided"

    assert has_element?(
             index,
             "[data-test='kpi'][data-kpi='tap_out_expiry'][data-severity='bad']"
           )

    assert has_element?(
             index,
             "[data-test='change'][data-kpi='tap_out_expiry'] a[href='#section-blocked']"
           )

    assert has_element?(index, "#section-blocked [data-test='tap-outs-chart']")
  end
end
