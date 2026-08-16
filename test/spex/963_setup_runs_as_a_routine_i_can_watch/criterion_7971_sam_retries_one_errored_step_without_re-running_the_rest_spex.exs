defmodule CodeMySpecSpex.Story963.Criterion7971Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7971 — Sam retries one errored step without re-running the rest.

  The status page offers a retry per step, and using it runs only that
  step. The other steps stay exactly as they were — a retry that
  re-executed the whole plan would re-touch working infrastructure to fix
  one broken piece.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Sam retries one errored step without re-running the rest" do
    scenario "retrying the errored step leaves every other step untouched" do
      given_ "the status page shows the email step errored and the others done", context do
        # Fails the first time and succeeds when retried, which is the whole
        # shape of this criterion. Scripting it that way says so directly; the
        # alternative was two cassettes and a provider that had to be persuaded
        # to fail once and then stop.
        {:ok, attempts} = Agent.start_link(fn -> 0 end)

        context =
          scripted_run(context, %{
            email: fn ->
              case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
                1 -> {:error, "Resend rejected the sending domain"}
                _ -> {:ok, []}
              end
            end
          })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='start-setup']") |> render_click()
        before = await_provisioning(view)

        assert before =~ ~r/data-step="email"[^>]*data-state="errored"/,
               "expected the first run to stop at the email step"

        {:ok, context |> Map.put(:view, view) |> Map.put(:before, before)}
      end

      when_ "Sam retries the email step", context do
        context.view
        |> element("[data-test='setup-step'][data-step='email'] [data-test='retry-step']")
        |> render_click()

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the email step moves to done", context do
        assert context.html =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected the retried step to succeed"

        {:ok, context}
      end

      then_ "every other step is exactly as it was", context do
        before_states = step_states(context.before) |> Map.delete("email")
        after_states = step_states(context.html) |> Map.delete("email")

        # Anchor: there were other steps to leave alone.
        assert map_size(before_states) > 0, "expected other steps to exist alongside email"

        assert after_states == before_states,
               "expected no other step to change on a single-step retry:\n  before: #{inspect(before_states)}\n  after:  #{inspect(after_states)}"

        {:ok, context}
      end
    end
  end

  defp step_states(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='setup-step']")
    |> Map.new(fn el ->
      {el |> Floki.attribute("data-step") |> List.first(),
       el |> Floki.attribute("data-state") |> List.first()}
    end)
  end
end
