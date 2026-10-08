defmodule CodeMySpecWeb.WorkingCopyLive.StatusTest do
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "shows only this copy's offers and pending decisions, and refreshes", ctx do
    copy = join_working_copy(ctx, "/tmp/status-one", "Status team")
    other = join_working_copy(ctx, "/tmp/status-other", "Other team")
    agent = agent(ctx, copy.working_copy_id)
    other_agent = agent(ctx, other.working_copy_id)
    Offers.record(nil, agent, :work, {"requirement", "visible-offer"})
    Offers.record(nil, other_agent, :work, {"requirement", "other-offer"})
    question(ctx, agent, "Visible question", "pending")
    question(ctx, other_agent, "Other question", "pending")
    question(ctx, agent, "Answered question", "answered")
    tap_out(ctx, agent, "Visible tap-out", "pending")
    tap_out(ctx, other_agent, "Other tap-out", "pending")
    tap_out(ctx, agent, "Approved tap-out", "approved")

    {:ok, view, _html} = live(ctx.conn, status_path(ctx, copy.working_copy_id))
    html = view |> element("[data-test=working-copy-status-page]") |> render()
    assert html =~ "Visible question"
    assert html =~ "Visible tap-out"
    refute html =~ "Other question"
    refute html =~ "Other tap-out"
    refute html =~ "Answered question"
    refute html =~ "Approved tap-out"
    assert has_element?(view, "#offer-results-#{agent.id}[aria-label='Offer results: Open: 1']")
    refute has_element?(view, "[data-test=offers-detail]")
    assert has_element?(view, "#questions-#{agent.id} summary", "1 pending")
    assert has_element?(view, "#tap-outs-#{agent.id} summary", "1 pending")

    question(ctx, agent, "New question", "pending")
    assert view |> element("button", "Refresh") |> render_click() =~ "New question"
  end

  test "a copy not on the project is refused", ctx do
    assert {:error, {:live_redirect, %{to: "/app/projects"}}} =
             live(ctx.conn, status_path(ctx, Ecto.UUID.generate()))
  end

  test "graph follows the current team's story, not historical reservations or retired agents",
       ctx do
    copy = join_working_copy(ctx, "/tmp/status-story", "Story team")
    other = join_working_copy(ctx, "/tmp/status-story-other", "Other story team")

    current =
      CodeMySpec.StoriesFixtures.story_fixture(ctx.scope, %{
        title: "Current team story",
        working_copy_id: copy.working_copy_id
      })

    historical =
      CodeMySpec.StoriesFixtures.story_fixture(ctx.scope, %{
        title: "Historical reservation",
        working_copy_id: copy.working_copy_id
      })

    elsewhere =
      CodeMySpec.StoriesFixtures.story_fixture(ctx.scope, %{
        title: "Other team story",
        working_copy_id: other.working_copy_id
      })

    retired = agent(ctx, copy.working_copy_id)

    retired
    |> Ecto.Changeset.change(
      story_id: historical.id,
      retired_at: DateTime.utc_now()
    )
    |> Repo.update!()

    agent(ctx, copy.working_copy_id)
    |> Ecto.Changeset.change(story_id: current.id)
    |> Repo.update!()

    agent(ctx, other.working_copy_id)
    |> Ecto.Changeset.change(story_id: elsewhere.id)
    |> Repo.update!()

    {:ok, view, _} = live(ctx.conn, status_path(ctx, copy.working_copy_id))
    render_async(view, 15_000)
    graph = view |> element("[data-test=story-requirements]") |> render()
    assert graph =~ "Current team story"
    refute graph =~ "Historical reservation"
    refute graph =~ "Other team story"
    refute has_element?(view, "select[name=story_id]")

    view |> form("form[phx-change=filter]", show_retired: "true") |> render_change()
    render_async(view, 15_000)
    graph = view |> element("[data-test=story-requirements]") |> render()
    assert graph =~ "Current team story"
    refute graph =~ "Historical reservation"
  end

  defp status_path(ctx, id),
    do: "/app/projects/#{ctx.project.id}/working-copies/#{id}/status"

  defp agent(ctx, copy_id) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: :coding,
        working_copy: "/tmp/status-#{copy_id}",
        working_copy_id: copy_id
      })

    agent
  end

  defp question(ctx, agent, title, status) do
    Repo.insert!(%QuestionRequest{
      user_id: ctx.user.id,
      agent_id: agent.id,
      title: title,
      status: status,
      questions: [%{"question" => title}]
    })
  end

  defp tap_out(ctx, agent, reason, status) do
    Repo.insert!(%PermissionRequest{
      user_id: ctx.user.id,
      agent_id: agent.id,
      tool_name: "tap_out",
      tool_input: %{"reason" => reason},
      status: status
    })
  end
end
