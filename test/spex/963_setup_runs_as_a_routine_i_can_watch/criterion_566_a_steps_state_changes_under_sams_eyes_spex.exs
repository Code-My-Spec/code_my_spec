defmodule CodeMySpecSpex.Story963.Criterion7960Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7960 — A step's state changes under Sam's eyes.

  A running step's state updates on the page Sam already has open — he
  does not reload to find out what happened, and the next step picks up
  visibly. That is the difference between watching a routine and polling
  a job.

  The assertion deliberately uses the *same* mounted view handle rather
  than re-mounting: a re-mount would pass even if the page never pushed
  an update, which is exactly the behaviour under test.

  Retargeted onto the console (provisioning-console-step6, unmerged):
  narrowed, per Harness/John — the original also watched the *next* step
  auto-pick-up, which was the whole-run cascade and genuinely has no home
  now that each step runs independently. What's left (a running step's own
  state updating live on a page Sam already has open, without a reload) is
  still true and still has a surface: `run_console_step/2` goes through the
  exact same `run_step_async/3` the old page's "Run" button did, so holding
  the *server* step itself open (instead of the step after it, since there
  is no "after" to watch pick up) and watching it move not_started → running
  → done on one held-open view proves the same mechanism.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # Watching a step change state needs a run that is still going.
  setup :watchable_run

  defp resource_step_state?(html, step, state),
    do: html =~ ~r/data-step="#{step}"[^>]*data-state="#{state}"/

  defp await_resource_step_state(view, step, state, deadline \\ nil)

  defp await_resource_step_state(view, step, state, nil) do
    await_resource_step_state(view, step, state, System.monotonic_time(:millisecond) + 30_000)
  end

  defp await_resource_step_state(view, step, state, deadline) do
    html = render(view)

    cond do
      resource_step_state?(html, step, state) ->
        html

      System.monotonic_time(:millisecond) > deadline ->
        raise "the #{step} step never reached #{state}"

      true ->
        Process.sleep(50)
        await_resource_step_state(view, step, state, deadline)
    end
  end

  spex "A step's state changes under Sam's eyes", criterion: 566 do
    scenario "the page moves a step from running to done without a reload" do
      given_ "setup is ready to run, with repository and secrets already done", context do
        # The server step itself is held open, because the claim is that Sam
        # *watches* its own transition. Scripted steps finish instantly, so
        # without this the state the criterion is about would be gone before
        # the page could show it — and the assertion would be about how fast
        # the test rendered, not about whether the page updates.
        own_repository(context.project)

        {hold, held_ref} = held_step()
        context = scripted_run(context, %{server: hold})

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(view, :secrets)
        await_resource_step_state(view, "secrets", "done")

        {:ok, Map.merge(context, %{view: view, held_ref: held_ref})}
      end

      when_ "the server step starts running", context do
        run_console_step(context.view, :server)

        html = await_resource_step_state(context.view, "server", "running")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "Sam sees it running on the page he already has open", context do
        assert resource_step_state?(context.html, "server", "running"),
               "expected the server step to show running on the already-open page"

        {:ok, context}
      end

      then_ "it moves to done without reloading", context do
        # Let the held step finish inside the scenario. Left holding, it
        # resumes and writes once the sandbox owner has gone — the straggler
        # shape that fails whichever spex is running at that moment.
        release_step(context.held_ref)
        html = await_resource_step_state(context.view, "server", "done")

        assert resource_step_state?(html, "server", "done"),
               "expected the server step to move to done on the same open page"

        {:ok, context}
      end
    end
  end
end
