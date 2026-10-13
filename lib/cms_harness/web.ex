defmodule CmsHarness.Web do
  @moduledoc """
  The harness's HTTP surface: the hook routes Claude Code posts to, a health
  check, and the Anthropic proxy a sprite's agent points `ANTHROPIC_BASE_URL`
  at.

  Loopback only, and unauthenticated on purpose — these requests come from a
  process on this machine, and that is the entire security model.

  Under `CmsHarness` rather than a `CmsHarnessWeb` peer of `CodeMySpecWeb`,
  because the two are one component and Boundary is right to say so. The core
  needs this layer's bound port (the server rewrites an agent's analysis command
  into a curl aimed at it), this layer calls the core on every hook, and one
  supervision tree starts both. That is a cycle between two boundaries and a
  single boundary containing one thing.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CmsHarness.Channel,
      CmsHarness.Project,
      CodeMySpec.BootVersion,
      CodeMySpec.Permissions
    ],
    exports: :all

  alias CmsHarness.Web.Endpoint

  # The server needs this and cannot know it. `pre-tool-use` rewrites the agent's
  # analysis command into a curl, and that curl points at this harness's own
  # endpoint — a URL that only means anything on the machine running the agent.
  # The server refuses to rewrite without it rather than pointing it somewhere
  # plausible, which would produce a command that runs and reports against the
  # wrong process.
  #
  # The *bound* port, not the configured one. They agree while the port is fixed
  # at 4005, but a configured `port: 0` means "pick one", and reading the config
  # back would hand the server a literal 0 — a curl to localhost:0, failing in a
  # way that says nothing about why.
  @spec bound_port() :: pos_integer() | nil
  def bound_port do
    case Endpoint.server_info(:http) do
      {:ok, {_ip, port}} when is_integer(port) and port > 0 -> port
      _ -> Endpoint.config(:http)[:port]
    end
  end
end
