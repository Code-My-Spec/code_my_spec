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
end
