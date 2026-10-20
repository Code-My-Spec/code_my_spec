defmodule CodeMySpecWeb.QaLiveChartTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup [:register_log_in_setup_account]

  setup %{scope: scope, account: account} do
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope, account_id: account.id)
    scope = %{scope | active_project_id: project.id, active_project: project}
    story = CodeMySpec.StoriesFixtures.story_fixture(scope, %{title: "Pay by card"})

    for {status, hours_ago} <- [{:fail, 48}, {:pass, 1}] do
      CodeMySpec.Repo.insert!(%CodeMySpec.Qa.QaAttempt{
        story_id: story.id,
        status: status,
        scenarios: [
          %CodeMySpec.Qa.Scenario{name: "it works", status: status, observation: "seen"}
        ],
        issue_ids: [],
        submitted_at: DateTime.add(DateTime.utc_now(), -hours_ago * 3600, :second)
      })
    end

    %{project: project}
  end

  defp option(view) do
    view
    |> element("[data-test='qa-over-time'] [phx-hook='EChart']")
    |> render()
    |> then(&Regex.run(~r/data-option="([^"]*)"/, &1, capture: :all_but_first))
    |> hd()
    |> String.replace("&quot;", ~s("))
    |> Jason.decode!()
  end

  defp last(option, status),
    do:
      option["series"] |> Enum.find(&(&1["name"] == status)) |> Map.fetch!("data") |> List.last()

  test "QA charts stories by where each stands, or every attempt", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/app/projects/#{project.id}/qa")

    # By story (the default): the story stands on its latest, the pass.
    assert has_element?(view, "[data-test='qa-view'] [data-view='stories'].btn-active")
    assert {last(option(view), "pass"), last(option(view), "fail")} == {1, 0}

    # All attempts: today's pass and the fail from two days back both count.
    view |> element("[data-test='qa-view'] [data-view='attempts']") |> render_click()
    attempts = option(view)

    total = fn status ->
      attempts["series"] |> Enum.find(&(&1["name"] == status)) |> Map.fetch!("data") |> Enum.sum()
    end

    assert {total.("pass"), total.("fail")} == {1, 1}
  end
end
