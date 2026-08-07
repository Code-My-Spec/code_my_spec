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
      server_url: Config.server_url(),
      credential: match?({:ok, _}, Config.credential()),
      projects: projects,
      # Said explicitly so that "serving nothing" cannot be read off a 200 as
      # "everything is fine".
      serving: length(projects),
      degraded: projects == [] or Enum.any?(projects, &(not &1.connected))
    })
  end
end
