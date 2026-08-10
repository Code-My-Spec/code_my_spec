defmodule CodeMySpecSpex.Story999.Criterion8303Spex do
  @moduledoc """
  Story 999 — I can fix what my setup is missing, and keep what I meant to leave
  Criterion 8303 — A fix that fails says which thing failed and leaves the rest alone.

  A bulk action across projects and providers will meet a refusal constantly —
  a sold-out server type, a domain someone else verified, an expired token. If
  one refusal stops everything, the button is useless on any account with more
  than one project. If one refusal is swallowed, the page reports done while
  something is still broken, which is worse.

  So: each project runs on its own, a failure halts that project and nothing
  else, and the account stays unhealthy rather than claiming success it did not
  have. The last part matters most — this whole page exists so that "we are
  fine" is a statement someone can rely on.

  "The rest" is the other project, not the later steps of the same one. Steps
  are ordered and depend on what came before, so halting the remainder of a
  project whose `email` step was refused is correct rather than collateral —
  the sequence is the dependency model. What must not happen is one project's
  refusal reaching across to another.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A fix that fails says which thing failed and leaves the rest alone" do
    scenario "one project's refusal does not stop the other" do
      given_ "two projects meant to be deployed, one of which the provider will refuse",
             context do
        recorder = Fixtures.call_recorder()

        context =
          scripted_run(context, %{
            # Before `email` in the sequence, so it is reachable in every
            # project regardless of what happens later.
            server: fn ->
              Fixtures.record_call(recorder, {:built, :server})

              {:ok,
               [
                 %{
                   kind: "server",
                   location: "hetzner/uat-box",
                   identifier: "environment=uat ip=203.0.113.10"
                 }
               ]}
            end,
            # A refusal the account cannot do anything about from here, which
            # is the ordinary case: capacity, or somebody else's verification.
            email: fn ->
              Fixtures.record_call(recorder, {:attempted, :email})
              {:error, "Resend refused the sending domain: already verified on another account"}
            end
          })

        {:ok, Map.put(context, :recorder, recorder)}
      end

      given_ "and a second project in the same account, also meant to be deployed", context do
        {:ok, form, _html} = live(context.conn, "/app/projects/new")

        form
        |> form("[data-test='project-form']", project: %{name: "second-project-999"})
        |> render_submit()

        # Said explicitly for this one too. DevOps is opt in, so a project
        # created and left alone expects no infrastructure — and this criterion
        # needs two projects that do. Named rather than addressed by id: the
        # create form redirects to the index, so the id is never in hand.
        CodeMySpecSpex.Fixtures.enable_devops(context.scope, "second-project-999")

        {:ok, context}
      end

      when_ "he fixes everything from the health page", context do
        context =
          stage_inventory(context, %{hetzner: [], cloudflare: [], resend: [], storage: []})

        {:ok, view, _html} = live(context.conn, "/app/resources")
        render_async(view, 5_000)

        view |> element("[data-test='fix-all']") |> render_click()

        {:ok, Map.merge(context, %{view: view, html: await_settled(view)})}
      end

      then_ "both projects were run, so one refusal did not stop the other", context do
        # Once per project. The second message is the whole claim: the first
        # project halted at `email`, and the second still got its turn.
        built = Fixtures.recorded_calls(context.recorder)

        assert Enum.count(built, &(&1 == {:built, :server})) == 2,
               "only one project was run, so a refusal in the first stopped the " <>
                 "second from being attempted at all — recorded: #{inspect(built)}"

        {:ok, context}
      end

      then_ "and the one that failed says which it was and what the provider said", context do
        document = Floki.parse_document!(context.html)

        # Scoped to one project. Both have an `email` entry now, and "is email
        # missing" has to be asked of a project rather than of the account.
        failed =
          Floki.find(
            document,
            "[data-test='checklist-item'][data-key='email']" <>
              "[data-project-id='#{context.project.id}']"
          )

        assert Floki.attribute(failed, "data-state") == ["missing"],
               "the step that was refused is not reported as still missing"

        text = Floki.text(document)

        assert text =~ "email", "the failure does not name which step it was"

        assert text =~ "already verified on another account",
               "the provider's own words are missing, and they are the only thing that " <>
                 "tells him whether this is his to fix"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and the account still reports unhealthy rather than claiming it is done",
            context do
        summary = Floki.find(context.document, "[data-test='health-summary']")

        assert Floki.attribute(summary, "data-status") == ["unhealthy"],
               "the page reported the account healthy after a fix that did not finish, " <>
                 "which is the one thing this page must never do"

        refute Floki.attribute(summary, "data-problems") == ["0"]

        {:ok, context}
      end
    end
  end

  # Settled means the run is no longer in flight, not that everything worked —
  # the point of this criterion is what the page says when it did not.
  defp await_settled(view, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_settled(view, deadline, nil)
  end

  defp await_settled(view, deadline, _last) do
    html = render(view)
    running? = html =~ "data-test=\"fix-running\""
    expired? = System.monotonic_time(:millisecond) > deadline

    settle_run(running?, expired?, html, view, deadline)
  end

  defp settle_run(false, _expired, html, _view, _deadline), do: html

  defp settle_run(true, true, _html, _view, _deadline), do: flunk("the fix never finished")

  defp settle_run(true, false, html, view, deadline) do
    Process.sleep(100)
    await_settled(view, deadline, html)
  end
end
