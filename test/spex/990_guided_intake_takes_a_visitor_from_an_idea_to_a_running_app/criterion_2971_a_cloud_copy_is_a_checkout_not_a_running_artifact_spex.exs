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

  alias CodeMySpec.Workspaces.PreviewTunnel

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  setup do
    start_workspace_runner([healthy?: true], boot_timeout: 5_000, poll_interval: 20)

    :ok
  end

  spex "A cloud project is a checkout the visitor owns, not an artifact we run" do
    scenario "A cloud copy is a checkout, not a running artifact" do
      given_ "a visitor who chose to have their project run in the cloud", context do
        # Cloudflare answering. The tunnel is real work against a real account,
        # so the spec stands in for the account and not for anything of ours —
        # `PreviewTunnel` still decides what to ask for and what to store.
        Req.Test.stub(PreviewTunnel, fn conn ->
          Req.Test.json(conn, %{
            "success" => true,
            "errors" => [],
            "result" => %{"id" => "tunnel-2971"}
          })
        end)

        conn = get(context.conn, "/build")
        {:ok, view, _html} = live(conn)

        describe_idea(view, "a booking tool for hair salons")
        answer_shaping_questions(view)

        confirm_plan(view, %{location: "cloud"})

        {:ok, context |> Map.put(:conn, conn) |> Map.put(:view, view)}
      end

      when_ "their working copy has been provisioned", context do
        {:ok, view, _html} = live(context.conn, "/build/workspace")

        # Cloud now pays before it provisions (990/3400) — not this
        # criterion's subject, so the payment step is cleared the way the
        # browser's own Stripe hook would, to reach the provisioning this
        # scenario is actually about.
        render_hook(view, "payment_confirmed", %{})

        {:ok, Map.merge(context, %{view: view, html: await(view, ~r/running/i)})}
      end

      when_ "the instance onboards itself the way the container does", context do
        # Everything the instance knows about itself, read back off what it was
        # started with. The container makes this call with exactly these two
        # values and no others, so a copy id or a credential that never reached
        # the environment fails here rather than being supplied by the spec.
        env = workspace_instance_env()

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{env["CMS_DEPLOY_KEY"]}")
          |> post("/api/harnesses/#{env["CMS_WORKING_COPY_ID"]}/preview")

        {:ok, Map.put(context, :onboarding, json_response(conn, 200))}
      end

      then_ "it appears among their working copies like any other", context do
        # Followed from the nav rather than typed, because the page is scoped to
        # a project and the visitor never learns its id. A spec that guesses the
        # path asserts on a URL; this asserts on the route they actually have.
        {:ok, _live, html} = live(context.conn, working_copies_path(context.conn))

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

  # The route the visitor walks: their projects, into the one they just made,
  # then "Working copies" in its nav. Walked rather than constructed, so a
  # cloud project that is missing from the list, or has no link to its copies,
  # fails here — which is the criterion, not a detour on the way to it.
  defp working_copies_path(conn) do
    project = follow(conn, ~p"/app/projects", ~r|/app/projects/[a-f0-9-]{36}"|, "their projects")

    follow(conn, project, ~r|/app/projects/[^"]+/working-copies|, "the project")
  end

  defp follow(conn, from, pattern, what) do
    html = conn |> get(from) |> html_response(200)

    pattern |> Regex.run(html) |> follow_match(what)
  end

  defp follow_match([path], _what), do: String.trim_trailing(path, ~s("))

  defp follow_match(nil, what) do
    flunk(
      "nothing on #{what} leads to the visitor's cloud project. A copy with " <>
        "no route to it is an artifact we run rather than a checkout they own."
    )
  end

  defp await(view, pattern, attempts \\ 250)

  defp await(view, pattern, 0),
    do: flunk("never rendered #{inspect(pattern)}: #{render(view)}")

  defp await(view, pattern, attempts) do
    html = render(view)
    await_result(html =~ pattern, html, view, pattern, attempts)
  end

  defp await_result(true, html, _view, _pattern, _attempts), do: html

  defp await_result(false, _html, view, pattern, attempts) do
    Process.sleep(20)
    await(view, pattern, attempts - 1)
  end
end
