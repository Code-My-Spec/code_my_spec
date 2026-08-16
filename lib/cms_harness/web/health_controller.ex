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
  alias CmsHarness.Project.ChannelClient
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
          watching: Watcher.watching?(root),
          # Belief and evidence, side by side.
          #
          # `connected` is this harness's own view of its socket, set at join.
          # It cannot be wrong from where it stands, and it reported `true`
          # throughout an incident where the server's registry held no entry for
          # this harness and every request answered `:harness_unreachable` —
          # both ends healthy, nothing doing a round trip.
          #
          # A reply is proof the server addressed us, because the server sent
          # it. Recorded on replies that already happen, so this adds no latency
          # and cannot hang: a health check that blocks on the network is its
          # own outage. `nil` means the server has never answered this channel,
          # which is a different fact from `connected: false`.
          server_replied_ago_s: ChannelClient.server_replied_ago(root),
          joined_ago_s: ChannelClient.joined_ago(root)
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
      degraded: projects == [] or Enum.any?(projects, &degraded?/1)
    })
  end

  # `connected` alone was the whole verdict, and it is belief: the harness's own
  # view of its socket, which cannot be wrong from where it stands. Through the
  # incident this endpoint exists to catch, it read `true` while the server's
  # registry held no entry for this harness and every request came back
  # unreachable — `serving 3, degraded false` the entire time.
  #
  # The evidence to correct that was already being *reported* and never
  # consulted. Now it is.
  @doc false
  # Public for the same reason `HookDecision.channel_age_note/1` is: the
  # readings can then be asserted without standing up a channel and a server to
  # not answer it.
  def degraded?(project), do: not project.connected or never_answered?(project)

  # Deliberately narrow. "Has not replied lately" is not evidence of anything —
  # a harness nobody is working in legitimately goes hours without a reply, and
  # calling that degraded would trade a false green for a false red, which is
  # the same mistake wearing the other colour.
  #
  # Never answered *at all*, well after joining, is the one reading that cannot
  # be innocent: the join succeeded locally and the server has not once
  # addressed us. A channel that has ever been answered stays healthy however
  # quiet it goes.
  @unanswered_grace_seconds 60

  defp never_answered?(%{connected: true, server_replied_ago_s: nil, joined_ago_s: joined})
       when is_integer(joined) and joined > @unanswered_grace_seconds,
       do: true

  defp never_answered?(_project), do: false

  # Rendered rather than raw, because the caller is usually a human or an agent
  # reading JSON, and `{:drifted, "abc123", "def456"}` does not survive that.
  defp drift do
    case BootVersion.drift() do
      {:drifted, booted, current} ->
        rendered(BootVersion.stale_kind(), booted, current) <>
          verdict(BootVersion.contract_changed?(booted, current))

      :none ->
        nil
    end
  end

  # Named separately from a moved checkout, because the remedies differ and only
  # one of them is "restart". A checkout behind its upstream relaunches the same
  # commit (9c474a9d).
  defp rendered(:behind_upstream, booted, current),
    do: "booted #{booted}, checkout behind upstream at #{current} — pull, then restart"

  defp rendered(_kind, booted, current), do: "booted #{booted}, checkout now #{current}"

  # Answered rather than left as a condition, for the same reason the stop
  # message answers it: a caller asking a health endpoint whether to restart
  # should not have to run `git diff` to interpret the reply.
  defp verdict(true), do: " — that range changed the harness or channel modules, so restart"
  defp verdict(false), do: " — that range did not touch the harness or channel modules"
  defp verdict(:unknown), do: " — could not read that range; restart if in doubt"
end
