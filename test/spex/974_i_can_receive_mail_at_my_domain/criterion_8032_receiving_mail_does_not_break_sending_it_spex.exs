defmodule CodeMySpecSpex.Story974.Criterion8032Spex do
  @moduledoc """
  Story 974 — I can receive mail at my domain
  Criterion 8032 — Receiving mail does not break sending it.

  The mirror image of story 969's criterion 8029. Publishing the inbound
  records leaves the sending domain verified and the app still able to
  send. 974 owns apex MX; 969 owns the `send` subdomain. Each must leave
  the other's records alone, and only asserting it in one direction would
  leave the other free to clobber.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.

  ## Against fakes, not cassettes

  Rewritten 2026-08-16, and it is the same argument as its mirror: the claim
  is about what our two steps do to each other's records, which is a
  before-and-after comparison of one zone. That needs a provider which
  remembers the before, and a recording is precisely the thing that cannot.

  Under cassettes it needed two of them, one per step, and each had to be
  recorded against a real domain in a real account. Both had already been
  named by another criterion once — recording this story silently destroyed
  another's tape, because record mode deletes the file when it opens and
  cassette names are global.

  What is not claimed here: that mail actually arrives. That is the drill's.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @domain "astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Receiving mail does not break sending it" do
    scenario "the sending domain stays verified after inbound records are published" do
      given_ "the app already sends verified mail from Sam's domain", context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        view = mount_provisioning(context)

        view
        |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
        |> render_click()

        CodeMySpecSpex.Case.await_step(view, :email)

        html = render(view)

        # Anchor: sending really was working before inbound touched anything.
        assert html =~ ~r/data-step="email"[^>]*data-state="done"/,
               "expected sending to be set up and verified first, got:\n#{step_states(html)}"

        {:ok,
         context
         |> Map.put(:view, view)
         |> Map.put(:before, zone_records(context))}
      end

      when_ "the inbound step publishes its records", context do
        context.view
        |> element("[data-test='setup-step'][data-step='inbound'] [data-test='run-step']")
        |> render_click()

        CodeMySpecSpex.Case.await_step(context.view, :inbound)

        {:ok,
         context
         |> Map.put(:html, render(context.view))
         |> Map.put(:after, zone_records(context))}
      end

      then_ "the send subdomain's records were left alone", context do
        assert send_records(context.after) == send_records(context.before),
               "expected the send subdomain's records to survive inbound setup:\n" <>
                 "  before: #{inspect(send_records(context.before))}\n" <>
                 "  after:  #{inspect(send_records(context.after))}"

        {:ok, context}
      end

      then_ "the inbound records went on the apex", context do
        added = context.after -- context.before

        refute added == [],
               "expected the inbound step to publish records, and it published none.\n" <>
                 "The steps are:\n#{step_states(context.html)}\n" <>
                 "The page says: #{inspect(escalation(context.html, "inbound"))}"

        assert Enum.any?(added, &apex?/1),
               "expected inbound delivery to be published at the apex, got: #{inspect(added)}"

        {:ok, context}
      end
    end
  end

  # The apex is written either way: `@` is how a zone file names it and how the
  # page renders it, and the fully-qualified zone name is what the API takes.
  # A criterion that accepted only one would fail on a correct publish.
  defp apex?(record), do: record["name"] in ["@", @domain]

  defp send_records(records) do
    records
    |> Enum.filter(&String.starts_with?(&1["name"], "send"))
    |> Enum.sort_by(&{&1["name"], &1["type"], &1["content"]})
  end

  defp step_states(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='setup-step']")
    |> Enum.map_join("\n", fn step ->
      "  #{attr(step, "data-step")}: #{attr(step, "data-state")}"
    end)
  end

  defp attr(element, name), do: element |> Floki.attribute(name) |> List.first()

  # What the page says about a step that stopped. An assertion reporting only
  # that nothing happened is the one thing already known when it fails.
  defp escalation(html, step) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='escalation'][data-step='#{step}']")
    |> Floki.text()
    |> String.trim()
  end
end
