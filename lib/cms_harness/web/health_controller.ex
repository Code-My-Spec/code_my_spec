defmodule CmsHarness.Web.HealthController do
  @moduledoc """
  Whether the harness is up, and — separately — what it can actually reach.

  Those are two different facts and this endpoint keeps them apart. A health
  check that returns 200 because the BEAM is running, while every project's
  channel is down, is the same class of answer as a stop hook that allows
  because it could not ask.
  """

  use Phoenix.Controller, formats: [:json]

  alias CmsHarness.Config
  alias CmsHarness.Project.Watcher
  alias CmsHarness.Projects
  alias CodeMySpec.BootVersion

  def index(conn, _params) do
    # Keyed and reported by working copy. Two checkouts of one project are two
    # entries here; reporting them by project id showed one and hid the other.
    projects =
      Enum.map(Projects.list(), fn root ->
        %{
          root: root,
          connected: Projects.connected?(root),
          watching: Watcher.watching?(root)
        }
      end)

    json(conn, %{
      status: "up",
      # Which code is answering, and whether its checkout has moved since.
      #
      # "Is my fix live" cost `lsof` to find the pid, then `git merge-base` to
      # place its checkout, every time — and got answered wrong more than once,
      # because a harness that reconnects looks identical to one running the
      # code you just pushed. `f32c4a4a` asked for this outright: a serving-root
      # or sha field would make it one request instead of a diagnosis.
      #
      # `drift` is the second half and the one that catches skew: a harness
      # keeps running while its checkout moves under it, and a server and
      # harness on different commits speak different channel contracts —
      # `{:error, %{"reason" => "unmatched topic"}}` on every stop, which reads
      # as a connection problem and is not one.
      build: BootVersion.describe(),
      build_drift: drift(),
      server_url: Config.server_url(),
      credential: match?({:ok, _}, Config.credential()),
      projects: projects,
      # Said explicitly so that "serving nothing" cannot be read off a 200 as
      # "everything is fine".
      serving: length(projects),
      degraded: projects == [] or Enum.any?(projects, &(not &1.connected))
    })
  end

  # Rendered rather than raw, because the caller is usually a human or an agent
  # reading JSON, and `{:drifted, "abc123", "def456"}` does not survive that.
  defp drift do
    case BootVersion.drift() do
      {:drifted, booted, current} ->
        "booted #{booted}, checkout now #{current} — restart if that range " <>
          "touched the harness or the channel contract"

      :none ->
        nil
    end
  end
end
