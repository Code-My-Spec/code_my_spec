defmodule CodeMySpecWeb.ProvisioningLive.Components.ContentConfig do
  @moduledoc """
  The content step's own markup, factored out of `step_card`'s branches.

  Uploading is not publishing: the step fetches the post back from the
  deployed site and checks the body carried its title, so the page shows
  what the site actually answered rather than that a file was merely
  written (criteria 8036, 8039). Which version is live matters on its own —
  a publish that fails verification leaves the last proven one serving, and
  Sam needs to see that what visitors get did not change under him (8038).
  Whose bucket each object landed in is "in Sam's own storage" made
  checkable (8035). Uploaded but not served is a different failure from a
  publish that never happened, and the difference is what Sam acts on
  (8038, 8058).
  """

  use CodeMySpecWeb, :html

  import CodeMySpecWeb.ProvisioningLive.ResourceFields

  attr :step, :map, required: true

  def content_config(assigns) do
    ~H"""
    <span
      :for={pr <- Enum.filter(@step.resources, &(&1.kind == "content_proof"))}
      data-test="content-render-proof"
      data-state={proof_field(pr.identifier, "state")}
      data-completed-at={proof_field(pr.identifier, "proven_at")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      rendered at {pr.location}: {pr.identifier}
    </span>

    <span
      :for={pr <- Enum.filter(@step.resources, &(&1.kind == "content_proof"))}
      data-test="content-render-check"
      data-status={proof_field(pr.identifier, "status")}
      data-path={pr.location}
      data-title-present={proof_field(pr.identifier, "title_present")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      {pr.location} answered {proof_field(pr.identifier, "status")}
    </span>

    <span
      :for={pr <- Enum.filter(@step.resources, &(&1.kind == "content_proof"))}
      data-test="content-served-version"
      data-version={proof_field(pr.identifier, "version")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      serving {proof_field(pr.identifier, "version")}
    </span>

    <span
      :for={obj <- Enum.filter(@step.resources, &(&1.kind == "content_object"))}
      data-test="content-object"
      data-key={obj.location}
      data-owner={proof_field(obj.identifier, "owner")}
      data-bucket={proof_field(obj.identifier, "bucket")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      {obj.location} → {proof_field(obj.identifier, "bucket")}
    </span>

    <span
      :for={f <- Enum.filter(@step.resources, &(&1.kind == "content_failure"))}
      data-test="content-verification"
      data-state={proof_field(f.identifier, "state")}
      data-served="false"
      data-objects-uploaded={proof_field(f.identifier, "objects_uploaded")}
      class="mt-1 block text-xs font-mono opacity-70"
    >
      <span data-test="content-publish-error">{f.location}</span>
    </span>
    """
  end
end
