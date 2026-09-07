defmodule CodeMySpecSpex.Story999.Criterion8302Spex do
  @moduledoc """
  Story 999 — I can fix what my setup is missing, and keep what I meant to leave
  Criterion 8302 — Fixing from the health page builds the missing thing and turns it green.

  A page that tells you what is wrong and then sends you somewhere else to fix
  it has made the problem visible and left the work where it was.

  The action is **the project's setup**, not the individual step. Steps depend
  on each other — `deploy` needs `server` needs `repository` — so a button that
  ran one step in isolation would fail whenever the gap was not the very next
  one, and fail in a way that reads like a broken feature rather than like an
  ordering constraint. Running the sequence is already idempotent (criterion
  7965), which is what makes it safe to offer as a fix: it converges on what is
  missing rather than rebuilding what is not.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Fixing from the health page builds the missing thing and turns it green" do
    scenario "the missing bucket is built without leaving the page" do
      given_ "a project whose setup stopped before storage, so it has no bucket", context do
        recorder = Fixtures.call_recorder()

        context =
          scripted_run(context, %{
            server: fn ->
              {:ok,
               [
                 %{
                   kind: "server",
                   location: "hetzner/uat-box",
                   identifier: "environment=uat ip=203.0.113.10"
                 }
               ]}
            end,
            # Records what setup built, so the second run can be checked for
            # having built only what was missing.
            storage: fn ->
              Fixtures.record_call(recorder, {:built, :storage})

              {:ok,
               [
                 %{
                   kind: "bucket",
                   location: "storage/fixture-uat",
                   identifier: "environment=uat"
                 }
               ]}
            end
          })

        {:ok, Map.put(context, :recorder, recorder)}
      end

      given_ "and the health page reports the account unhealthy because of it", context do
        context =
          stage_inventory(context, %{hetzner: [], cloudflare: [], resend: [], storage: []})

        {:ok, view, _html} = live(context.conn, "/app/resources")
        html = render_async(view, 5_000)

        assert html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='health-summary']")
               |> Floki.attribute("data-status") == ["unhealthy"],
               "expected the account to start unhealthy, or this proves nothing"

        assert html =~ "data-test=\"missing-item\"",
               "nothing is reported missing, so there is nothing to fix"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he fixes it from that page", context do
        context.view
        |> element("[data-test='run-setup'][phx-value-project-id='#{context.project.id}']")
        |> render_click()

        {:ok, Map.put(context, :html, await_no_missing(context.view))}
      end

      then_ "the bucket is created at the provider", context do
        assert {:built, :storage} in Fixtures.recorded_calls(context.recorder),
               "the fix reported success without the storage step ever running"

        {:ok, context}
      end

      then_ "and the checklist entry turns from missing to present", context do
        storage =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='checklist-item'][data-key='storage']")

        # One entry per environment now — the scripted step succeeds the same
        # way regardless of which environment invoked it, so every row should
        # have turned present.
        states = Floki.attribute(storage, "data-state")

        assert states != [] and Enum.all?(states, &(&1 == "present")),
               "the bucket was built and the page still says it is missing, so he has " <>
                 "no way to tell the fix worked, got #{inspect(states)}"

        {:ok, context}
      end

      then_ "and nothing that was already in place is created a second time", context do
        # The server was already there. A fix that rebuilt it would be a fix
        # that costs money and interrupts traffic to close a gap somewhere
        # else entirely.
        refute {:built, :server} in Fixtures.recorded_calls(context.recorder),
               "the fix rebuilt a server that already existed"

        {:ok, context}
      end
    end
  end

  # The run is asynchronous, so the page catches up rather than answering
  # immediately. Waiting on the checklist rather than on a step's state,
  # because the checklist is what this criterion is about.
  defp await_no_missing(view, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_no_missing(view, deadline, nil)
  end

  defp await_no_missing(view, deadline, _last) do
    html = render(view)
    missing? = html =~ "data-test=\"missing-item\""
    expired? = System.monotonic_time(:millisecond) > deadline

    settle_missing(missing?, expired?, html, view, deadline)
  end

  defp settle_missing(false, _expired, html, _view, _deadline), do: html

  defp settle_missing(true, true, html, _view, _deadline) do
    still =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-test='missing-item']")
      |> Floki.attribute("data-key")

    flunk("still missing after the fix ran: #{inspect(still)}")
  end

  defp settle_missing(true, false, html, view, deadline) do
    Process.sleep(100)
    await_no_missing(view, deadline, html)
  end
end
