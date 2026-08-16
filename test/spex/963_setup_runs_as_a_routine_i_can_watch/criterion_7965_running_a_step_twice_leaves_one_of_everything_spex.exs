defmodule CodeMySpecSpex.Story963.Criterion7965Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7965 — Running a step twice leaves one of everything.

  Steps converge rather than accumulate. Running the server step a second
  time leaves one server per environment and one firewall, and reports
  success — it does
  not error out complaining the resources already exist, and it does not
  create duplicates Sam then pays for.

  ## Against fakes, not cassettes

  Rewritten 2026-08-16, and this criterion is why the fakes exist.

  Its claim is idempotency in *our* step — that we look before we create — and
  it has nothing to do with Hetzner. Under cassettes it cost about a hundred
  seconds and a real server per run, and it could not replay at all
  (`c635d90e`): the server step SSHes, `with_provider_cassette` records HTTP
  only, so a replay really connected to a box destroyed when the recording
  ended and spent 82 seconds waiting out the timeout.

  Moving to `with_full_cassette` fixed the SSH and revealed the next thing, and
  the next: the secrets step has to run first because the server step reads the
  env file it writes, and both need one working directory rather than a fresh
  temp root each. Then it recorded green and *still* replayed red, because the
  recording's first run really wrote a key with `ssh-keygen` and its second
  found it — while a replay writes nothing, so its second run asked for a
  command the recording had no reason to contain.

  Against fakes that remember, the whole thing is a sentence: create a server,
  create it again, see one server and a step that says done. The Hetzner fake
  refuses a duplicate name with a 409 exactly as Hetzner does, so this tests
  our adoption rather than our optimism.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :fake_working_directory

  spex "Running a step twice leaves one of everything" do
    scenario "a second run of the server step converges instead of duplicating" do
      given_ "the server step already provisioned a server and a firewall", context do
        own_repository(context.project)

        view = mount_provisioning(context)

        # Secrets first: the server step reads the environment file secrets
        # writes, and `sops` cannot operate on a file that is not there. The
        # sequence is repository → secrets → server.
        for step <- [:secrets, :server] do
          view
          |> element("[data-test='setup-step'][data-step='#{step}'] [data-test='run-step']")
          |> render_click()

          CodeMySpecSpex.Case.await_step(view, step)
        end

        assert render(view) =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the first run to make a server before the second is asked to " <>
                 "converge. The page says: #{inspect(escalation(render(view)))}"

        {:ok, context |> Map.put(:view, view) |> Map.put(:after_first, servers(context))}
      end

      when_ "the server step runs a second time", context do
        context.view
        |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
        |> render_click()

        CodeMySpecSpex.Case.await_step(context.view, :server)

        {:ok,
         context
         |> Map.put(:html, render(context.view))
         |> Map.put(:after_second, servers(context))}
      end

      then_ "the step reports success rather than an already-exists error", context do
        assert context.html =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the repeated run to succeed, not error on existing resources. " <>
                 "The page says: #{inspect(escalation(context.html))}"

        refute context.html =~ ~r/data-step="server"[^>]*data-state="errored"/,
               "expected no already-exists failure on the second run"

        {:ok, context}
      end

      then_ "there is one of everything, not two", context do
        assert context.after_second == context.after_first,
               "expected the second run to adopt what the first made:\n" <>
                 "  after one run:  #{inspect(context.after_first)}\n" <>
                 "  after two runs: #{inspect(context.after_second)}"

        {:ok, context}
      end
    end
  end

  # One server per environment: each environment gets its own box, which is
  # what makes it an environment. Idempotence is "no environment gained a
  # second server", not "there is only one server".
  defp servers(context) do
    context
    |> fake(:hetzner)
    |> Agent.get(& &1.servers)
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  defp escalation(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='escalation'][data-step='server']")
    |> Floki.text()
    |> String.trim()
  end
end
