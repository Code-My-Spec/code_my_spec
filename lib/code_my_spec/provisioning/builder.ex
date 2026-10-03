defmodule CodeMySpec.Provisioning.Builder do
  @moduledoc """
  Build a project's image on the environment's one shared burst box.

  Nothing is built when a project is created. Building happens when Sam
  deploys, which is the only moment anyone knows what to build — coupling it to
  project creation made every new project wait on a build before it was usable,
  and coupled "my history reached the remote" to "CI finished", which are two
  different claims (story 992).

  The box used to be created fresh per build and destroyed when the build
  ended. Story 877 replaced that: `build/3` now asks
  `CodeMySpec.Provisioning.BurstBox.ensure_box/3` for the one persistent box
  this account already has (or gets, the first time), and asks
  `BurstBox.Lifecycle.check/3` whether to free it the moment this build is
  done — the happy-path call `Lifecycle`'s own moduledoc describes, rather
  than waiting on `BurstBox.Sweep`'s next tick. Per-build isolation is now
  Docker's job, not a Hetzner server boundary: builds from different projects
  on the same account's box run as separate containers in parallel, and
  `CodeMySpec.Provisioning.RunLock` (held by whoever calls `run_step/3`,
  above this module) still serializes same-project builds — the ordering
  that actually matters, never cross-project ordering on a box Docker already
  isolates.

  Publishing is `Registry`'s. This owns the build.
  """

  require Logger

  alias CodeMySpec.Integrations
  alias CodeMySpec.Provisioning.Builder.Remote
  alias CodeMySpec.Provisioning.BurstBox
  alias CodeMySpec.Provisioning.BurstBox.Lifecycle
  alias CodeMySpec.Provisioning.Deploy
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Wait
  alias CodeMySpec.Users.Scope

  defmodule Build do
    @moduledoc "What a finished build produced, and what it cost."

    @type t :: %__MODULE__{
            image: String.t(),
            architecture: :arm | :x86,
            builder: String.t(),
            builder_image: String.t(),
            builder_destroyed: boolean(),
            built_at: DateTime.t(),
            deploy: term()
          }

    defstruct [
      :image,
      :architecture,
      :builder,
      :builder_image,
      :builder_destroyed,
      :built_at,
      :deploy
    ]
  end

  # Hetzner's two lines, and the box each architecture builds on. A build has
  # to happen on the architecture it will run on: an image built for the other
  # one fails at container start, which is a deploy that looks healthy right up
  # until the swap.
  #
  # A size up from the app servers, deliberately. A builder is CPU-bound and
  # lives for minutes, so the trade is nothing like a server that runs for
  # months: cax21 doubles the cores and the memory of cax11 for €0.009/hour
  # more, which on a five-minute build is a tenth of a cent. On x86 it is not
  # even a trade — cpx11 has 2GB, and an Elixir release compile is not
  # something to attempt in 2GB.
  #
  # Checked against the live API rather than the docs, as with the server
  # types: cax11 €0.0112/h, cax21 €0.0200/h, cpx11 2GB, cpx21 4GB.
  # Checked against `/datacenters`, which is the only place that says what can
  # actually be created right now. Two things it said that the docs do not:
  #
  #   * No ARM type is available in any datacenter today. cax11 and cax21 are
  #     still listed and not deprecated, so this is Hetzner being sold out
  #     rather than a removal — CAX goes in and out of stock. An arm builder is
  #     therefore a request that may simply fail, and says so.
  #   * There is a newer x86 generation the docs do not lead with. cpx32 is 4
  #     cores and 8GB for €0.0673/h, against cpx21's 3 cores and 4GB for
  #     €0.0601 — more of both forseven thousandths of a euro an hour.
  #
  # cpx31 rather than cpx32, and the difference is only where they exist.
  #
  # They are identical on paper — 4 cores, 8GB — but cpx32 is offered in fsn1,
  # hel1, nbg1 and sin, while cpx31 is in every location including ash and hil.
  #
  # This comment used to say a builder "is gone in minutes, so where it runs
  # matters far less than what it costs". That was true when the builder pushed
  # to a registry somewhere else. It is not true now: the builder joins the app
  # box's private network, and a network subnet lives in exactly one zone, so
  # the builder has to be created in the app box's own location. A type that
  # does not exist in half of them is a builder that cannot be placed — which
  # the API says as "unsupported location for server type", found by asking
  # /server_types rather than by reading the docs.
  @builders %{
    arm: %{server_type: "cax21", location: "fsn1"},
    x86: %{server_type: "cpx31", location: "fsn1"}
  }

  # The same mechanism `create_image/3` writes a snapshot's id with — a
  # Hetzner label, the only way a snapshot is found again without storing its
  # id anywhere this account could lose track of.
  @burst_box_image_label "cms-burst-image-role"

  @doc """
  Build `ref` for `architecture` on the environment's one shared burst box,
  freeing it the moment this build is the last thing using it.

  `:build_fun` is injectable because a container build is a bad thing to record —
  enormous output, non-deterministic layer digests, minutes per run, and
  invalidated by any Dockerfile edit. What is worth proving is ours: the
  architecture asked for, that the shared box is asked about after every
  build — success, failure or raise alike — and that a mismatch is caught
  rather than shipped. The Hetzner calls stay real, because "the box was
  checked" is exactly the claim that costs money when it silently stops being
  true.
  """
  @spec build(Scope.t(), String.t(), keyword()) :: {:ok, Build.t()} | {:error, term()}
  def build(%Scope{} = scope, ref, opts \\ []) when is_binary(ref) do
    architecture = Keyword.get(opts, :architecture, :arm)

    with {:ok, spec} <- builder_spec(architecture),
         {:ok, server} <- ensure_box(scope, architecture, spec, opts) do
      Logger.info(
        "[Builder] #{architecture} burst box #{server_name(server)} is up — building #{ref}"
      )

      # A build outlives a raise, a non-zero exit and an early return alike,
      # and the box is shared — so every path still has to ask whether it
      # should be freed, the same discipline this used to apply to an
      # unconditional destroy of a box no caller could use again anyway. The
      # abnormal paths only ask; there is no result left to decorate.
      try do
        result = run(scope, server, ref, architecture, opts)
        log_build_outcome(result, server)
        record_disposition(result, server, release_box(scope, server, opts))
      rescue
        error ->
          _ = release_box(scope, server, opts)
          reraise error, __STACKTRACE__
      catch
        kind, value ->
          _ = release_box(scope, server, opts)
          :erlang.raise(kind, value, __STACKTRACE__)
      end
    end
  end

  # `:server_type`/`:location` forwarded explicitly so a box that has to be
  # *created* gets the CPU-bound builder sizing above rather than
  # `BurstBox.ensure_box/3`'s own app-server-sized default — the common case
  # (the box already exists) never looks at either, `Hetzner.find_server/2`
  # is one list call and nothing else.
  defp ensure_box(scope, architecture, spec, opts) do
    ensure = Keyword.get(opts, :ensure_box, &BurstBox.ensure_box/3)

    box_opts =
      opts
      |> Keyword.put(:architecture, architecture)
      |> Keyword.put(:server_type, Keyword.get(opts, :server_type) || spec.server_type)
      |> Keyword.put(:location, Keyword.get(opts, :builder_location) || spec.location)

    ensure.(scope, BurstBox.box_name(), box_opts)
  end

  # The box is shared and persistent now (story 877) — nothing here destroys
  # it outright any more. Every path still asks `Lifecycle.check/3` eagerly,
  # which is the happy-path caller its own moduledoc already describes: an
  # idle box is freed the moment the last job of its billing hour ends,
  # rather than waiting on `BurstBox.Sweep`'s next tick. `Sweep` itself is
  # the safety net for whatever puts a box on the board in the first place,
  # builds included, and is untouched by this.
  defp release_box(scope, server, opts) do
    busy? = Keyword.get(opts, :busy?, &BurstBox.busy?/2)
    destroy = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    Lifecycle.check(scope, server, busy?: busy?, destroy: destroy, now: now)
  end

  # The only line that says a build actually finished, one way or the other
  # — without it, "silence" and "still going" read identically in the logs,
  # which is the exact question there was no way to answer live against
  # MarketMySpec's own first real runs through this path.
  defp log_build_outcome({:ok, %Build{} = build}, server) do
    Logger.info("[Builder] #{server_name(server)} built #{build.image}")
  end

  defp log_build_outcome({:error, reason}, server) do
    Logger.warning("[Builder] #{server_name(server)} failed: #{inspect(reason)}")
  end

  # `builder_destroyed` now means what `release_box/3` actually decided —
  # `:deleted` when the shared box was idle at the end of its billing hour,
  # `false` for `:kept`/`:not_due`/an error. `builder_image` is read off the
  # box's own Hetzner record (`server_image/1`) rather than a constant: there
  # is only one kind of image a burst box ever boots from now
  # (`ensure_burst_box_image/3`'s own snapshot), so the honest per-build
  # answer is whatever that box's record actually says it was created from,
  # not a value this module decided on the caller's behalf.
  defp record_disposition({:ok, %Build{} = build}, server, disposition) do
    {:ok,
     %{build | builder_destroyed: disposition == :deleted, builder_image: server_image(server)}}
  end

  # A failed build has a disposition too, and it is the one most worth having:
  # "the box was checked even when the build fails" is exactly the claim
  # that rots quietly, because a failed deploy already looks like a failure
  # and a box left running an extra billed hour adds nothing visible to it.
  defp record_disposition({:error, reason}, server, disposition) do
    {:error, reason,
     %{
       builder: server_name(server),
       builder_image: server_image(server),
       builder_destroyed: disposition == :deleted
     }}
  end

  defp record_disposition(other, _server, _disposition), do: other

  defp builder_spec(architecture) do
    case Map.fetch(@builders, architecture) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_architecture, architecture}}
    end
  end

  @doc """
  The burst box's own snapshot for `architecture` — docker-ce and kamal, the
  same as any Hetzner box this codebase builds on, *plus* this app's own OTP
  release installed directly on the box, found by label if one already
  exists, built once if not (story 877).

  A burst box's own embedding runners need the release on the box itself,
  not inside a container: "our own embedding jobs on it run as FLAME
  runners, no container layer needed — it's our own trusted workload."
  Customer builds on the same box still run in throwaway Docker containers
  (criteria 789/790), which is exactly what docker-ce and the kamal gem are
  still for.

  `:install_release` is required and has no default: `(run, server, opts ->
  :ok | {:error, term()})`, called once, after kamal and before the disk is
  synced for the snapshot — same place `ensure_kamal/1` itself runs. This
  module does not know how a release gets built — same reason `:create`,
  `:destroy` and `:build_fun` elsewhere in this file are injected rather than
  called directly — but the shape a real caller wires up is: build this
  app's own `Dockerfile` for `ref` the same way `Remote.build/4` already
  builds a customer's, then extract `/app` from the built image
  (`docker create` + `docker cp` + `docker rm`) onto the box's filesystem
  rather than pushing it anywhere or running it as a container.

  One snapshot per Hetzner account: `list_images/2` is already scoped to the
  calling account's own token, so a customer's environment and ours can
  never find each other's burst-box image by accident, and nothing here
  assumes a snapshot is portable across accounts at all.
  """
  @spec ensure_burst_box_image(Scope.t(), :arm | :x86, keyword()) ::
          {:ok, String.t() | integer()} | {:error, term()}
  def ensure_burst_box_image(%Scope{} = scope, architecture, opts \\ []) do
    list_images = Keyword.get(opts, :list_images, &Hetzner.list_images/2)
    selector = "#{@burst_box_image_label}=#{architecture}"

    case list_images.(scope, label_selector: selector, status: "available") do
      {:ok, [image | _]} -> {:ok, image["id"]}
      {:ok, []} -> build_burst_box_image(scope, architecture, opts)
      {:error, _reason} = error -> error
    end
  end

  # A temporary box, bootstrapped, snapshotted, destroyed either way — a box
  # this leaves behind is one nobody is watching on an invoice somebody pays.
  defp build_burst_box_image(scope, architecture, opts) do
    with {:ok, spec} <- builder_spec(architecture) do
      create = Keyword.get(opts, :create, &Hetzner.create_server/3)
      destroy = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)
      create_image = Keyword.get(opts, :create_image, &Hetzner.create_image/3)
      install_release = Keyword.fetch!(opts, :install_release)
      name = "cms-burst-bootstrap-#{architecture}-#{System.unique_integer([:positive])}"

      create_opts = [
        server_type: spec.server_type,
        location: Keyword.get(opts, :builder_location) || spec.location,
        # The Hetzner marketplace image this temporary bootstrap box boots
        # from — not a bare OS. Every system image Hetzner offers is the
        # same 5GB minimal cloud image, so the weight that matters is not
        # the image, it is what has to be installed before the box can do
        # its job; `docker-ce` already has Docker, which is the one thing
        # every snapshot built from it needs. 40GB disk, which this spec's
        # server types clear comfortably.
        image: "docker-ce",
        ssh_key_ids: Keyword.get(opts, :ssh_key_ids),
        network_ids: Keyword.get(opts, :network_ids)
      ]

      case create.(scope, name, create_opts) do
        {:ok, server} ->
          opts =
            opts
            |> Keyword.put(:image_label, @burst_box_image_label)
            |> Keyword.put(:extra_bootstrap, install_release)
            |> Keyword.put_new(
              :image_description,
              "CodeMySpec burst box (#{architecture})"
            )

          bootstrap_and_snapshot(scope, server, architecture, destroy, create_image, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  # The source server is not destroyed until the snapshot Hetzner is taking
  # *of* it is confirmed done. `create_image/3`'s own moduledoc says the
  # caller polls for the image to actually appear rather than trusting a
  # bare "accepted" response — the image the initial response names is
  # `status: "creating"`, and deleting its source while Hetzner is still
  # reading from it is exactly the timing bug this discipline exists to
  # close.
  defp bootstrap_and_snapshot(scope, server, architecture, destroy, create_image, opts) do
    run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)
    attempts = Keyword.get(opts, :ssh_attempts, 90)
    list_images = Keyword.get(opts, :list_images, &Hetzner.list_images/2)
    label = Keyword.fetch!(opts, :image_label)
    description = Keyword.fetch!(opts, :image_description)

    result =
      with :ok <- Remote.await_ssh(run, attempts, opts),
           :ok <- Remote.ensure_kamal(run),
           :ok <- maybe_extra_bootstrap(run, server, opts),
           :ok <- sync_disk(run),
           {:ok, %{"image" => image}} <-
             create_image.(scope, server_id(server),
               description: description,
               labels: %{label => to_string(architecture)}
             ),
           :ok <- await_image_ready(list_images, scope, image["id"], architecture, label, opts) do
        {:ok, image["id"]}
      end

    destroy_temp_server(destroy, scope, server, architecture)
    result
  end

  defp maybe_extra_bootstrap(run, server, opts) do
    case Keyword.get(opts, :extra_bootstrap) do
      nil -> :ok
      step -> step.(run, server, opts)
    end
  end

  # A process exiting 0 says its writes were issued, not that they have
  # reached disk — the kernel buffers and flushes them lazily, on its own
  # schedule. `create_image` snapshots the block device as it is at that
  # instant, with no coordination with the filesystem, so anything still
  # sitting in the page cache is what a torn, crash-consistent snapshot
  # loses. Confirmed live against MarketMySpec: every gemspec `gem install
  # kamal` had just written came back "isn't a Gem::Specification (NilClass
  # instead)" — a real gem install that ran to completion, snapshotted a few
  # seconds too early. `sync` forces the flush `ensure_kamal`'s own exit
  # status can't promise, the same reason every cloud provider's own
  # snapshot guidance says to run it first.
  #
  # Never fatal to the build — `sync` failing is rare enough, and stopping
  # the whole bootstrap over it would refuse a snapshot that might still be
  # fine, when logging loudly and proceeding costs nothing a caller cannot
  # already see for itself in the image it gets back.
  defp sync_disk(run) do
    case run.(["sync"]) do
      {_, 0} ->
        :ok

      {output, status} ->
        Logger.warning(
          "[Builder] sync before snapshot reported exit #{status}: #{String.trim(output)}"
        )

        :ok
    end
  end

  # `_ = destroy.(...)` was the original shape here, and it is exactly the
  # kind of silent discard this codebase warns against elsewhere: a refused
  # or failed delete left no trace anywhere a caller — or a log — could ever
  # see it, so a temp bootstrap box stuck on an account's invoice looked
  # identical to one that was cleanly destroyed. Logged loudly rather than
  # threaded into the return value: a cleanup failure must not turn a
  # successful image build into a failed one, but it must not vanish either.
  defp destroy_temp_server(destroy, scope, server, architecture) do
    case destroy.(scope, server_id(server)) do
      {:ok, _} ->
        :ok

      other ->
        Logger.error(
          "[Builder] could not destroy temporary #{architecture} bootstrap server " <>
            "#{server_id(server)} after building its image: #{inspect(other)}. " <>
            "It is still running and being billed; delete it manually or via " <>
            "mix cms.provisioning_leaks."
        )
    end
  end

  # Same shape as `Remote.await_ssh/4` — a plain poll for the observable
  # effect, not an action id. Hetzner reports a snapshot as `status:
  # "creating"` for a real span (bigger disks take longer), and nothing
  # downstream — `Hetzner.create_server/3` asked to build from this image,
  # or the source server this function is about to let its caller delete —
  # is safe to run against an image still in that state.
  defp await_image_ready(list_images, scope, image_id, architecture, label, opts, attempts \\ 30)

  defp await_image_ready(_list_images, _scope, image_id, _architecture, _label, _opts, 0) do
    {:error, {:image_not_ready, image_id}}
  end

  defp await_image_ready(list_images, scope, image_id, architecture, label, opts, attempts) do
    selector = "#{label}=#{architecture}"

    case list_images.(scope, label_selector: selector, status: "available") do
      {:ok, images} ->
        if Enum.any?(images, &(&1["id"] == image_id)) do
          :ok
        else
          Wait.sleep(Keyword.get(opts, :image_poll_interval_ms, 3_000))
          await_image_ready(list_images, scope, image_id, architecture, label, opts, attempts - 1)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp run(scope, server, ref, architecture, opts) do
    # `:build_fun`, not `:build`. The deploy step's opts are threaded straight
    # through to here, and there `:build` is the boolean asking for an image to
    # be built at all — so `build: true` arrived as the build function and this
    # died with "expected a function, got: true" the first time a real drill
    # asked for a real build. Two meanings for one key in one opts bag.
    build_fun =
      Keyword.get(opts, :build_fun, fn scope, server, ref, architecture ->
        docker_build(scope, server, ref, architecture, opts)
      end)

    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    with {:ok, image} <- build_fun.(scope, server, ref, architecture),
         :ok <- matches?(image, architecture, opts) do
      {:ok,
       %Build{
         image: image.reference,
         architecture: image.architecture,
         builder: server_name(server),
         built_at: now.(),
         deploy: run_then(server, opts)
       }}
    end
  end

  # `:then` runs on the same box, over the same SSH the build already
  # delivered the source and pushed the image with — never a second box, and
  # never the environment of whichever caller triggered this run. `bin/deploy`
  # is meant to connect *to* the app server, not run on the box being deployed
  # and not on wherever a caller happens to be shelling out from — a harness
  # cannot shell out at all, and even a real local checkout would mean the
  # deploy is no longer reproducibly the platform's own.
  #
  # `nil` when no caller asked for one, which is every existing caller —
  # `Build.deploy` staying `nil` is the ordinary case, not a degraded one.
  #
  # `then_fun` invokes `bin/deploy`, which shells out to `kamal` directly —
  # never installed here before, because nothing had ever gotten a real
  # harness-only project's deploy this far. Refused as a `Deploy.Result`
  # rather than a bare error tuple so it still matches
  # `deploy_result(_scope, _environment, _host, %{deploy: %Deploy.Result{}}, _opts)`
  # — an untyped error here would fall through to that clause's sibling,
  # which reaches for `env(scope)` directly and crashes the exact way this
  # session spent tonight fixing.
  defp run_then(server, opts) do
    case Keyword.get(opts, :then) do
      nil ->
        nil

      then_fun ->
        run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)

        case Remote.ensure_kamal(run) do
          :ok ->
            then_fun.(run, Keyword.get(opts, :build_dir, "/build"))

          {:error, {status, output}} ->
            %Deploy.Result{
              failed_phase: :build,
              reason: "could not install kamal on the builder (exit #{status}): #{output}"
            }
        end
    end
  end

  # An image whose architecture is not the one the servers run cannot start
  # there, and the failure arrives at container start rather than at build
  # time — long after the deploy has decided it is going well. Caught here so
  # it is never published (criterion 8235).
  defp matches?(%{architecture: architecture}, architecture, _opts), do: :ok

  defp matches?(%{architecture: built}, wanted, _opts),
    do: {:error, {:architecture_mismatch, built: built, wanted: wanted}}

  # The real thing, on the box this module just made. Everything it needs that
  # is not the box — where the source is, where the image goes, which key opens
  # the door — arrives in `opts`, because the builder should not be the module
  # that knows how a project is addressed.
  defp docker_build(scope, server, ref, _architecture, opts) do
    case Keyword.get(opts, :reference) do
      nil ->
        {:error, :no_image_reference}

      reference ->
        Remote.build(server, ref, reference, with_deliver(opts, server, scope))
    end
  end

  # `Remote.ssh_deliver/2`'s own default is the stronger property (no GitHub
  # credential anywhere near the builder) and stays untouched whenever there
  # is a real environment to archive from. A harness-only project's
  # `scope.environment` is not one — same shape `Steps.head_commit/1` and
  # `commit_generated_configuration/1` already fall back for — so this is the
  # one place that falls back to a different property instead of a fact to
  # report: there is no string that answers "here is the source tree".
  defp with_deliver(opts, _server, %{environment: %{cwd: cwd}}) when is_binary(cwd), do: opts

  defp with_deliver(opts, server, scope) do
    case github_source(scope) do
      {:ok, repo, token} ->
        opts
        |> Keyword.put(:github_repo, repo)
        |> Keyword.put(:github_token, token)
        |> then(&Keyword.put(&1, :deliver, Remote.github_deliver(server, &1)))

      {:error, reason} ->
        Keyword.put(opts, :deliver, fn _ref, _dir ->
          {:error, {:source_delivery_failed, :no_reachable_source, inspect(reason)}}
        end)
    end
  end

  defp github_source(%Scope{active_project: %{code_repo: url}} = scope)
       when is_binary(url) and url != "" do
    with {:ok, token} <- Integrations.fetch_access_token(scope, :github) do
      {:ok, repo_path(url), token}
    end
  end

  defp github_source(_scope), do: {:error, :no_repository}

  defp repo_path(url) do
    url
    |> String.trim_trailing(".git")
    |> String.split("/")
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  defp server_id(%{"id" => id}), do: id
  defp server_id(%{"server" => %{"id" => id}}), do: id

  defp server_name(%{"name" => name}), do: name
  defp server_name(%{"server" => %{"name" => name}}), do: name
  defp server_name(_), do: nil

  # Read off the box's own Hetzner record rather than assumed — the same
  # "read, don't assume" discipline `server_architecture/1` already applies
  # to a live server object. `"unknown"` rather than a raise or a stale
  # guess: the box's own data not saying is the same shape of gap
  # `check_architecture/2` already treats as non-fatal elsewhere in this
  # file.
  defp server_image(%{"image" => %{"description" => description}})
       when is_binary(description) and description != "",
       do: sanitize_image(description)

  defp server_image(%{"image" => %{"name" => name}}) when is_binary(name) and name != "",
    do: sanitize_image(name)

  defp server_image(%{"image" => %{"id" => id}}), do: to_string(id)
  defp server_image(%{"server" => server}), do: server_image(server)
  defp server_image(_server), do: "unknown"

  # `Steps.builder_resource/1` packs this into a `"key=value key=value"`
  # identifier string, read back apart by splitting on spaces
  # (`ResourceFields.identifier_field/2`) — the same format every other
  # provisioning resource already uses. A description like "CodeMySpec burst
  # box (arm)" is several words, and `@builder_image` (the single-word
  # "docker-ce" this replaced) never had to account for that — read back
  # through that parser unchanged, only the first word would survive. One
  # token, so the round trip is exact.
  defp sanitize_image(value), do: String.replace(value, " ", "_")
end
