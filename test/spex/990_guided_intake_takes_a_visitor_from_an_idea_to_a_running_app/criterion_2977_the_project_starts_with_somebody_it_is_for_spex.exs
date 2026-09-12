defmodule CodeMySpecSpex.Story990.Criterion2977Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2977 — The project starts with somebody it is for.

  Rule: who the visitor said they are building for becomes a persona on the
  project, not a sentence used once and thrown away.

  `Intake.convert/2` already does this (`record_persona/3`) — intake asks
  `who_uses` for the shaper's own reasons, and the answer is spent again here
  rather than invented a second time when `personas_complete` first asks for
  one. This is the user-visible half: the persona is there, without anyone
  having to add it by hand before the first Three Amigos can run.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  @who "salon owners see their week, and their clients book themselves in"

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)
    :ok
  end

  spex "Who the visitor said this is for becomes a persona on the project" do
    scenario "The project starts with somebody it is for" do
      given_ "a visitor describing a booking tool for hair salon owners", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salon owners")
        answer_shaping_questions(view, [@who])

        to =
          confirm_plan(view, %{
            account_name: "Acme",
            project_name: "Salon Book",
            location: "cloud"
          })

        assert to == "/build/workspace",
               "expected a signed-in visitor to be sent to their workspace, got #{inspect(to)}"

        {:ok, _workspace_view, _html} = live(conn, to)

        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "their project is created", context do
        project_id = find_new_project_id(context.conn, "Salon Book")

        {:ok, Map.put(context, :project_id, project_id)}
      end

      then_ "the project has a persona for the person they said they are building for",
            context do
        {:ok, _live, html} = live(context.conn, "/app/projects/#{context.project_id}/personas")

        assert html =~ "salon owners",
               "expected a persona built from what the visitor said intake was for, got: " <>
                 "#{html}"

        {:ok, context}
      end
    end
  end

  # The route the visitor walks to the project they just made: their
  # projects list. This account has exactly one project — the one intake
  # just created — so its name only has to appear on the page at all; the id
  # is whichever single project link is there.
  defp find_new_project_id(conn, project_name) do
    html = conn |> get("/app/projects") |> html_response(200)

    assert html =~ project_name,
           "expected the project intake just created to appear on /app/projects, got: #{html}"

    case Regex.run(~r|/app/projects/([a-f0-9-]{36})|, html) do
      [_, id] -> id
      nil -> flunk("could not find any project link on /app/projects, got: #{html}")
    end
  end
end
