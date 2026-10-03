defmodule CodeMySpec.Workspaces.HarnessSource do
  @moduledoc """
  How a `Runner.Local`-booted workspace's companion harness comes to be
  running — a customer's own installed release, or this box's own checkout
  run straight from source.

  Docker never had this problem: `docker/devbox/Dockerfile` builds
  `cms_harness` fresh from `.` on every image build, so a promoted fix
  reaches the next boot automatically. Bare metal's `cms start` resolves
  through PATH to whatever release happens to be installed — which is
  exactly right for a customer's laptop (`Installed`, the published tap, on
  whatever cadence that ships) and exactly wrong for this dev box, where it
  silently decoupled every harness-side fix from the promote pipeline this
  project otherwise trusts.

  Measured 2026-09-21: the installed `codemyspec` formula was three weeks
  behind this repo's own HEAD, missing an Alloy provider a bare-metal
  workspace's own agent needed just to restore — `:unknown_provider`, on a
  project whose harness had joined correctly, at the correct root, and
  asked to restore an agent the server correctly told it to. Every other fix
  from that same night (`CMS_NODE_NAME`, `CMS_PROJECT_DIR`, the working-copy
  root sync, the join-time reap race) lives in this same tree and had never
  once reached a real bare-metal boot on this box, regardless of how many
  times `promote_sync` said otherwise — because none of it is the server;
  all of it is the harness, and the harness was never the thing promoted.

      config :code_my_spec, CodeMySpec.Workspaces, harness_source: MySource
  """

  @doc "The shell command that starts this workspace's harness."
  @callback command() :: String.t()
end
