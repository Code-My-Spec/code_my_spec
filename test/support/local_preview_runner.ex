defmodule CodeMySpecTest.LocalPreviewRunner do
  @moduledoc """
  A workspace runner for an app that is genuinely listening, but not in Docker.

  Fakes exactly one thing — `alive?/1`, the "is there a container" question —
  and answers everything else for real. `serving/1` delegates to the Docker
  runner, which is an actual HTTP probe of the port, so the distinction
  criterion 2326 rests on (up and answering vs up and raising) is still being
  drawn by the code that draws it in production, not by an Agent holding an
  atom the test chose.

  `CodeMySpecTest.FakeWorkspaceRunner` is the right tool when the scenario is
  about the container's lifecycle — booting, dying, never answering. This one
  is for the proxy scenarios, where the container is beside the point and the
  app has to be real.
  """

  @behaviour CodeMySpec.Workspaces.Runner

  alias CodeMySpec.Workspaces.Runner.Docker

  @impl true
  def start(_container_name, _app_name, _port), do: :ok

  @impl true
  def stop(_container_name), do: :ok

  @impl true
  def alive?(_container_name), do: true

  @impl true
  def logs(_container_name), do: ""

  @impl true
  defdelegate healthy?(port), to: Docker

  @impl true
  defdelegate serving(port), to: Docker

  @impl true
  def url(_container_name, port), do: "http://localhost:#{port}"
end
