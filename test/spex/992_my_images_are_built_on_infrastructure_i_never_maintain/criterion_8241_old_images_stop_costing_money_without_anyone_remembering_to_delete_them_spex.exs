defmodule CodeMySpecSpex.Story992.Criterion8241Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8241 — Old images stop costing money without anyone remembering to
  delete them.

  Registries fill disks silently, because every image ever built stays until
  something deletes it. "Something" must not be a person: a retention that
  depends on remembering is a retention that lapses.

  So the assertion is about *who enforces it*, not merely that a number exists.
  A window we prune on a schedule of our own would stop the moment that
  schedule stopped, and nothing would say so. The bucket's own lifecycle rule
  expires blobs whether or not setup ever runs again — the same mechanism as
  the backups' retention (8016), pointed at the registry's blob prefix.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # Fakes rather than cassettes: the claim is that *we* record a retention the
  # bucket enforces, which is about our step and not about Hetzner. Under
  # cassettes the deploy step reached Hetzner outside any recording and errored
  # with `cannot find mock/stub`, so the criterion reported "nothing says when
  # images expire" for a step that never got as far as an image.
  setup :fake_providers
  setup :real_working_directory

  spex "Old images stop costing money without anyone remembering to delete them" do
    scenario "the registry expires old images on its own" do
      given_ "Sam has deployed, so an image exists", context do
        {:ok, built_deploy_run(context)}
      end

      when_ "he deploys", context do
        view = mount_provisioning(context)
        view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, await_provisioning(view))}
      end

      then_ "images expire after a stated window", context do
        retention =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='image-retention']")

        # Say what the run did, not only that the element is absent. The
        # retention is recorded by the deploy step when it produces an image,
        # so "nothing says when images expire" has two very different causes —
        # the feature is missing, or the build never happened — and the bare
        # assertion cannot tell them apart.
        assert retention != [],
               "nothing says when images expire, so they accumulate until a disk fills.\n" <>
                 "The steps are:\n#{step_states(context.html)}\n" <>
                 "The deploy step says: #{inspect(escalation(context.html, "deploy"))}"

        assert [days] = Floki.attribute(retention, "data-days")
        assert String.to_integer(days) > 0, "images are kept for zero days"

        {:ok, Map.put(context, :retention, retention)}
      end

      then_ "and nobody has to run anything for that to happen", context do
        assert Floki.attribute(context.retention, "data-enforced-by") == ["bucket_lifecycle"],
               "retention is enforced by something that has to keep running — which means " <>
                 "it lapses the first time it does not"

        {:ok, context}
      end
    end
  end

  defp step_states(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='setup-step']")
    |> Enum.map_join("\n", fn step ->
      "  #{attr(step, "data-step")}: #{attr(step, "data-state")}"
    end)
  end

  # The deploy step renders its provider error in its own block rather than in
  # the escalation, so reading only the escalation gets "run the deploy step"
  # and nothing about why it stopped.
  defp escalation(html, step) do
    parsed = Floki.parse_document!(html)

    [
      parsed |> Floki.find("[data-test='escalation'][data-step='#{step}']") |> Floki.text(),
      parsed |> Floki.find("[data-test='boot-failure']") |> Floki.text()
    ]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" — ")
  end

  defp attr(element, name), do: element |> Floki.attribute(name) |> List.first()
end
