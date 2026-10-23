defmodule CmsHarness.Web.HealthController do
  @moduledoc """
  Whether the harness is up, and — separately — what it can actually reach.

  Two facts, kept apart: a 200 because the BEAM runs while every channel is
  down would be a false green. Nothing here blocks on the network.
  See knowledge/harness, "Health".
  """

  use Phoenix.Controller, formats: [:json]

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.Channel
  alias CmsHarness.Config
  alias CmsHarness.Project.Watcher
  alias CmsHarness.Projects
  alias CodeMySpec.BootVersion

  def index(conn, _params) do
    # One entry per working copy, never per project.
    projects =
      Enum.map(Projects.list(), fn root ->
        %{
          root: root,
          connected: Projects.connected?(root),
          watching: Watcher.watching?(root),
          # Belief (`connected`, set at join) beside evidence (the last server
          # reply, recorded on replies that already happen). `nil` means the
          # server has never answered this channel.
          server_replied_ago_s: Channel.server_replied_ago(root),
          joined_ago_s: Channel.joined_ago(root),
          # A 403 is terminal (issue 62377cc3 / 620b0389): the server named
          # a reason, and nothing here retries it on a timer. Non-nil is
          # where a person running the harness is meant to see it.
          terminal_refusal: Channel.terminal_refusal(root),
          # Whether this copy can run anything: without a recorded test
          # partition every analyzer run raises, while `connected` and
          # `watching` both read true. A file read, not a network call.
          onboarded: onboarded?(root)
        }
      end)

    json(conn, %{
      status: "up",
      # Which code is answering, and whether its checkout has moved since:
      # a harness on an older channel contract than the server fails every
      # stop with what reads as a connection problem.
      build: BootVersion.describe(),
      build_drift: drift(),
      server_url: Config.server_url(),
      device_id: CmsHarness.Device.recorded_id(),
      credential: match?({:ok, _}, Config.credential()),
      projects: projects,
      # Explicit, so "serving nothing" is never read off a 200 as fine.
      serving: length(projects),
      degraded: projects == [] or Enum.any?(projects, &degraded?/1)
    })
  end

  # Belief alone is not the verdict: degraded when not connected, not
  # onboarded, or never answered. Public so the readings can be tested without
  # a channel.
  @doc false
  def degraded?(project),
    do: not project.connected or not project.onboarded or never_answered?(project)

  # No recorded partition means every analyzer run raises: degraded, and
  # fixable with one command.
  defp onboarded?(root) do
    match?({:ok, _partition}, Onboarding.resolve_partition(root))
  end

  # Deliberately narrow: a quiet channel is not degraded. Only one never
  # answered at all, well after joining, cannot be innocent.
  @unanswered_grace_seconds 60

  defp never_answered?(%{connected: true, server_replied_ago_s: nil, joined_ago_s: joined})
       when is_integer(joined) and joined > @unanswered_grace_seconds,
       do: true

  defp never_answered?(_project), do: false

  # Rendered for a human or agent reading JSON.
  defp drift do
    case BootVersion.drift() do
      {:drifted, booted, current} ->
        rendered(BootVersion.stale_kind(), booted, current) <>
          verdict(BootVersion.contract_changed?(booted, current))

      :none ->
        nil
    end
  end

  # Behind upstream: a restart alone relaunches the same commit.
  defp rendered(:behind_upstream, booted, current),
    do: "booted #{booted}, checkout behind upstream at #{current} — pull, then restart"

  defp rendered(_kind, booted, current), do: "booted #{booted}, checkout now #{current}"

  # Answers whether to restart, rather than leaving the caller to diff.
  defp verdict(true), do: " — that range changed the harness or channel modules, so restart"
  defp verdict(false), do: " — that range did not touch the harness or channel modules"
  defp verdict(:unknown), do: " — could not read that range; restart if in doubt"
end
