defmodule CodeMySpecWeb.ProvisioningLive.Components.DeployConfig do
  @moduledoc """
  The deploy step's own markup, factored out of `step_card`'s branches —
  the largest of them, since deploy records more about itself than any
  other step.

  Deploying is a decision about one environment, never a batch operation —
  confirmed live against cleaner_crm: two unscoped calls both deployed prod
  first (environments have no defined order) and never reached uat, because
  a run halts on the first failure. The plain "Run"/"Retry" buttons are
  hidden for this step so there is no path left that deploys every
  environment in one click; there is no environment picker either, because
  each deploy step is already its own card, one per environment.

  The rest is what a deploy records about itself: the key's delivery (a
  property of configuration, not of one run, so it shows whether the deploy
  then succeeds or fails); each phase, migration completing before the swap
  starts (8007), and on a failure which phase stopped it and which version
  stayed live (8008, 8009); the image and whether this deploy built it
  (8234/8235); the box it built on — shared and persistent since story 877,
  so "destroyed" now means `BurstBox.Lifecycle` decided this build was the
  last one using it, asked on every path out regardless of outcome
  (8236/8237); retention, enforced by one of two mechanisms per deploy and
  never both (6dcb62b8, 8241); the version actually shipped and the one
  actually live; and a deploy or boot failure.
  """

  use CodeMySpecWeb, :html

  import CodeMySpecWeb.ProvisioningLive.ResourceFields

  attr :step, :map, required: true
  attr :age_key_environments, :list, required: true
  attr :runs_in_flight?, :boolean, required: true

  def deploy_config(assigns) do
    ~H"""
    <form
      data-test="deploy-environment-form"
      phx-submit="run_step_with_environment"
      class="mt-3 flex flex-wrap gap-2 items-end"
    >
      <input type="hidden" name="key" value={@step.key} />
      <input type="hidden" name="environment" value={@step.environment} />
      <.button
        type="submit"
        data-test="deploy-environment-submit"
        class="btn btn-primary"
        disabled={@runs_in_flight?}
      >
        {if @step.state == :errored, do: "Retry", else: "Deploy"} {@step.environment}
      </.button>
    </form>

    <div
      :if={@age_key_environments != []}
      data-test="age-key-delivery"
      data-via="deploy_env"
      data-manual-step-required="false"
      class="mt-2 text-xs opacity-70"
    >
      key for {Enum.join(@age_key_environments, ", ")} supplied by the deploy
    </div>

    <span
      :for={ph <- Enum.filter(@step.resources, &(&1.kind == "deploy_phase"))}
      data-test="deploy-phase"
      data-phase={ph.location}
      data-completed-at={ph.location == "migrate" && ph.identifier}
      data-started-at={ph.location == "swap" && ph.identifier}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      {ph.location} at {ph.identifier}
    </span>

    <span
      :for={img <- Enum.filter(@step.resources, &(&1.kind == "published_image"))}
      data-test="published-image"
      data-image={img.location}
      data-built={img.identifier |> String.split(" ") |> hd() |> String.replace_prefix("built=", "")}
      data-architecture={image_architecture(img)}
      data-registry={img.location |> String.split("/") |> hd()}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      image {img.location}
    </span>

    <span
      :for={b <- Enum.filter(@step.resources, &(&1.kind == "builder"))}
      data-test="builder"
      data-builder={b.location}
      data-destroyed={identifier_field(b, "destroyed")}
      data-booted-from={identifier_field(b, "booted_from")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      built on {b.location}, destroyed after
    </span>

    <span
      :for={
        r <-
          Enum.filter(@step.resources, fn r ->
            r.kind == "image_retention" and identifier_field(r, "enforced_by") == "bucket_lifecycle"
          end)
      }
      data-test="image-retention"
      data-days={r.location |> String.replace_suffix(" days", "")}
      data-enforced-by="bucket_lifecycle"
      class="mt-1 block text-xs font-mono opacity-70"
    >
      images expire after {r.location}
    </span>

    <span
      :for={
        r <-
          Enum.filter(@step.resources, fn r ->
            r.kind == "image_retention" and identifier_field(r, "enforced_by") == "prune_on_push"
          end)
      }
      data-test="image-retention"
      data-images={r.location |> String.replace_suffix(" images", "")}
      data-enforced-by="prune_on_push"
      class="mt-1 block text-xs font-mono opacity-70"
    >
      the registry keeps the newest {r.location}
    </span>

    <span
      :for={dv <- Enum.filter(@step.resources, &(&1.kind == "deployed_version"))}
      data-test="deployed-version"
      data-image={dv.location}
      data-commit={dv.identifier |> String.split(" ") |> hd() |> String.replace_prefix("commit=", "")}
      data-source={
        dv.identifier |> String.split(" ") |> List.last() |> String.replace_prefix("source=", "")
      }
      data-image-source={
        dv.identifier |> String.split(" ") |> List.last() |> String.replace_prefix("source=", "")
      }
      class="mt-1 block text-xs font-mono opacity-70"
    >
      shipped {dv.location}
    </span>

    <span
      :for={lv <- Enum.filter(@step.resources, &(&1.kind == "live_version"))}
      data-test="live-version"
      data-version={lv.location}
      data-role={lv.location}
      class="mt-1 block text-xs opacity-70"
    >
      live version: {lv.location}
    </span>

    <p
      :for={f <- Enum.filter(@step.resources, &(&1.kind == "deploy_failure"))}
      data-test="deploy-failure"
      data-phase={f.identifier}
      class="mt-2 text-xs text-error"
    >
      {f.location}
    </p>

    <p
      :if={@step.state == :errored and @step.provider_error}
      data-test="boot-failure"
      class="mt-2 text-xs text-error"
    >
      {@step.provider_error}
    </p>
    """
  end
end
