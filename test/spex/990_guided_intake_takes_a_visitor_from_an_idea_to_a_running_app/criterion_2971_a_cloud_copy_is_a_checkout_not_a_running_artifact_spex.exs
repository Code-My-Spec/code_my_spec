defmodule CodeMySpecSpex.Story990.Criterion2971Spex do
  @moduledoc """
  Story 990 — Guided intake takes a visitor from an idea to a running app.
  Criterion 2971 — A cloud copy is a checkout, not a running artifact.

  Rule: A cloud working copy is a real checkout in a development container on a
  shared box, onboarded the same way a laptop's is.

  This is the decision that keeps the product to one concept. A container that
  merely *ran* the visitor's app would be a second kind of thing: not editable,
  no agent in it, no hooks, no requirements — and every question about "my
  project" would then have two answers depending on where it happened to live.

  So the container holds a checkout. `docker/devbox/` already generates one with
  `mix cms.new` and starts a harness beside it; what this criterion adds is that
  the copy is *onboarded*, which is what turns a directory into a working copy —
  it gets an identity, a row the visitor can see, and a preview through story
  968's provisioning with nothing new modelled.

  ## Observed where the visitor would see it

  Through their working copies page rather than by inspecting the container.
  "It is a checkout" is a claim about what the person can do with it, and a
  container that held one but never surfaced it would satisfy an inspection and
  fail the visitor.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IntakeSteps

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    :ok
  end

  spex "A cloud project is a checkout the visitor owns, not an artifact we run" do
    scenario "A cloud copy is a checkout, not a running artifact" do
      given_ "a visitor who chose to have their project run in the cloud", context do
        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        view
        |> form("form[phx-submit=choose_location]", %{location: "cloud"})
        |> render_submit()

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "their working copy has been provisioned", context do
        {:ok, view, _html} = live(context.conn, "/build/workspace")

        {:ok, Map.merge(context, %{view: view, html: await(view, ~r/running/i)})}
      end

      then_ "it appears among their working copies like any other", context do
        {:ok, _live, html} = live(context.conn, ~p"/app/working-copies")

        assert html =~ ~r/working cop/i,
               "the visitor's cloud project is not on the page that lists what they " <>
                 "have. A copy they cannot see is one they cannot put an agent in, " <>
                 "which makes it an artifact we run rather than a project they own."

        {:ok, Map.put(context, :copies_html, html)}
      end

      then_ "its preview was set up by the same onboarding a laptop's would run", context do
        assert context.copies_html =~ "preview-",
               "the cloud copy has no preview address, so onboarding did not run in " <>
                 "the container. Story 968 provisions one for any main checkout — a " <>
                 "copy that skipped it is not onboarded the same way a laptop's is, " <>
                 "which is exactly what this criterion denies."

        {:ok, context}
      end
    end
  end

  defp await(view, pattern, attempts \\ 250)

  defp await(view, pattern, 0),
    do: flunk("never rendered #{inspect(pattern)}: #{render(view)}")

  defp await(view, pattern, attempts) do
    html = render(view)

    if html =~ pattern do
      html
    else
      Process.sleep(20)
      await(view, pattern, attempts - 1)
    end
  end
end
