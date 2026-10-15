defmodule CodeMySpecWeb.ProvisioningLive.Components.RepositoryConfig do
  @moduledoc """
  The repository step's own markup, factored out of `step_card`'s branches
  the same way `StatusBadge` and `ResourceCard` were — a plain function
  component, `events` still handled by `ProvisioningLive` (`adopt_repository`,
  `rename_repository`).

  Two pieces: the commit a push actually landed (criterion 8183 — the step is
  proven by a push, not by the repository existing, and an empty repository
  looks exactly like "it exists" when the push failed), and the name
  collision dialog for when the repository exists but is not this project's
  (criterion 8185 — adopting a stranger's repo or inventing a suffixed name
  are both decisions Sam makes, not defaults taken for him).
  """

  use CodeMySpecWeb, :html

  attr :step, :map, required: true

  def repository_config(assigns) do
    ~H"""
    <div
      :for={commit <- Enum.filter(@step.resources, &(&1.kind == "commit"))}
      data-test="push-proof"
      data-commit={commit.location}
      class="mt-2 text-xs font-mono opacity-70"
    >
      pushed {String.slice(commit.location, 0, 12)}
    </div>

    <form
      :if={@step.state != :running}
      id="adopt-repository-form"
      phx-submit="adopt_repository"
      data-test="adopt-repository-form"
      class="mt-3 flex flex-wrap items-end gap-2"
    >
      <.input name="owner" value="" label="GitHub owner or organization" required />
      <.input name="name" value="" label="Existing repository name" required />
      <.button type="submit">Adopt existing repository</.button>
    </form>

    <div
      :if={@step.state == :paused}
      data-test="repository-collision"
      class="mt-3 flex gap-2"
    >
      <.button
        data-test="adopt-existing-repository"
        phx-click="adopt_repository"
        class="btn btn-warning"
      >
        Adopt the existing repository
      </.button>
      <.button data-test="choose-another-name" phx-click="rename_repository">
        Use a different name
      </.button>
    </div>
    """
  end
end
