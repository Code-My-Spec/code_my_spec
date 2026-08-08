defmodule CmsHarness.Supervisor do
  @moduledoc """
  The harness's supervision tree.

  Built up from nothing rather than copied from the full local application and
  trimmed. That application boots sixteen children; what survives a deletion
  pass is whatever nobody was sure about, which is how it ends up heavy again.
  Every child below is here because something demonstrably does not work
  without it, and the justification is written next to it.

  Notably absent, and each absence is a decision:

    * **No Repo, no Vault, no migrator.** The harness holds no database. It
      talks to the server for Files, leases, and hook decisions. Wanting a Repo
      here is the signal that something belongs on the server instead.
    * **No PubSub.** Nothing subscribes to anything. The processes that need to
      talk are in the same project subtree and find each other through the
      registry, by name. A PubSub with no subscribers is scaffolding.
    * **No Presence, no MCP server, no LiveView.** The tools moved to the
      server; the endpoint below serves hook routes and nothing else.
    * **No embedding serving.** Inference is phase 6. The seam is the channel —
      vectors will ride it in batches, content-addressed by fingerprint. It is
      not stubbed here, because a stub is indistinguishable from the real thing
      having silently stopped working.

  A child spec rather than an `Application` callback so the tree has two
  callers: `cms harness`, where it is the whole process, and the test suite,
  where it hangs off whichever application `mix test` booted. Tests here drive
  real processes rather than constructing them, so they need the real tree —
  and a second `Application` in one OTP app was never an option.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # A hook arrives as an HTTP request carrying a working directory, and
      # something has to turn that into that project's channel client. Without
      # a registry the endpoint cannot reach into the subtree at all. Keyed by
      # `{kind, root}` so one registry serves every process in a project,
      # and a dead process deregisters itself.
      {Registry, keys: :unique, name: CmsHarness.Registry},

      # Projects arrive at runtime — from the environment on a sprite, from a
      # hook's working directory on a laptop — so the tree cannot be static.
      # This is also the fix for a real defect: the server's watcher is a
      # singleton managing every project at once, so one project's crash stops
      # watching for all of them. A subtree each means a wedged project
      # restarts alone.
      {DynamicSupervisor, name: CmsHarness.ProjectSupervisor, strategy: :one_for_one},

      # Holds the short-lived token the deploy key buys, and serialises buying
      # it: several hooks and an MCP call arrive at once on a cold start, and N
      # simultaneous exchanges for one key is N-1 tokens nobody uses.
      CmsHarness.Token,

      # Claude Code POSTs its hooks to a fixed URL. This is that URL.
      CmsHarness.Web.Endpoint

      # Last, because it needs both the registry and the dynamic supervisor.
      # `:temporary`, which is what `{Task, fun}` means, so a failure here does
      # not take the harness down: a hook can still name its own working
      # directory, and a harness that is up and serving nothing is far easier to
      # diagnose than one that would not boot.
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
