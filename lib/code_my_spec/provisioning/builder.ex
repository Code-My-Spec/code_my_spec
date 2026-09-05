defmodule CodeMySpec.Provisioning.Builder do
  @moduledoc """
  Build a project's image on a box that exists only for that build.

  Nothing is built when a project is created. Building happens when Sam
  deploys, which is the only moment anyone knows what to build — coupling it to
  project creation made every new project wait on a build before it was usable,
  and coupled "my history reached the remote" to "CI finished", which are two
  different claims (story 992).

  The box is created from a pre-warmed image so the layers every project shares
  — the base OS, the language toolchain — are already there, and destroyed when
  the build ends. Per-build isolation is the other half of that: one customer's
  source never sits on a box that held another's.

  Publishing is `Registry`'s. This owns the box and the build.
  """

  require Logger

  alias CodeMySpec.Integrations
  alias CodeMySpec.Provisioning.Builder.Remote
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

  # The Docker app image, not a bare OS.
  #
  # Every system image Hetzner offers is the same 5GB minimal cloud image —
  # Debian is not lighter than Ubuntu here, they are the same size. So the
  # weight that matters is not the image, it is what has to be installed before
  # the box can do its job. A bare OS pays `apt-get install docker` on every
  # single build: a minute or two, and a dependency on apt mirrors being up
  # during a customer's deploy.
  #
  # `docker-ce` asks for a 40GB disk, which both cax21 and cpx21 clear
  # comfortably. It is heavier on paper and much lighter in practice.
  @builder_image "docker-ce"

  # Shared with `builder_name/1` below and with the age-based reap, so a
  # renamed prefix cannot silently stop matching one of the two places that
  # depend on it recognizing the same boxes.
  @builder_prefix "builder-"

  # How a custom builder image is found again without storing its id
  # anywhere this account could lose track of — a Hetzner label, the same
  # mechanism `create_image/3` writes it with.
  @builder_image_label "cms-builder-role"

  # How old a `builder-*` box has to be before it stops being read as
  # in-flight. A build either finishes or fails in minutes (see moduledoc);
  # nothing here is legitimately long-lived, so a box past this age is not
  # somebody's run in progress, it is the box a killed process — SIGKILL, a
  # killed `mix test`, a cancelled drill — never got a chance to destroy
  # (issue 13ad1abe). An hour matches the window `mix cms.provisioning_leaks`
  # already uses for the same judgment call.
  @orphan_max_age_minutes 60

  @doc """
  Build `ref` for `architecture`, and take the builder with it either way.

  `:build_fun` is injectable because a container build is a bad thing to record —
  enormous output, non-deterministic layer digests, minutes per run, and
  invalidated by any Dockerfile edit. What is worth proving is ours: the
  architecture asked for, that the builder is destroyed even when the build
  fails, that a mismatch is caught rather than shipped. The Hetzner calls stay
  real, because "the builder was destroyed" is exactly the claim that costs
  money when it silently stops being true.
  """
  @spec build(Scope.t(), String.t(), keyword()) :: {:ok, Build.t()} | {:error, term()}
  def build(%Scope{} = scope, ref, opts \\ []) when is_binary(ref) do
    architecture = Keyword.get(opts, :architecture, :arm)

    with {:ok, spec} <- builder_spec(architecture),
         opts = with_builder_image(scope, architecture, opts),
         {:ok, server} <- start_builder(scope, ref, spec, opts) do
      Logger.info(
        "[Builder] #{architecture} builder #{server_name(server)} is up " <>
          "(image #{inspect(Keyword.get(opts, :builder_image, @builder_image))}) — building #{ref}"
      )

      # A builder outlives a raise, a non-zero exit and an early return alike,
      # and each of those leaves a box nobody is watching on an invoice
      # somebody is paying. So every path destroys.
      #
      # Spelled out rather than left to `after` because the outcome is worth
      # recording: "the builder was destroyed" asserted from a constant is a
      # claim that keeps reading true after it stops being true. The abnormal
      # paths still only have to destroy, since there is no result to decorate.
      try do
        result = run(scope, server, ref, architecture, opts)
        log_build_outcome(result, server)
        record_disposition(result, server, destroy(scope, server, opts), opts)
      rescue
        error ->
          _ = destroy(scope, server, opts)
          reraise error, __STACKTRACE__
      catch
        kind, value ->
          _ = destroy(scope, server, opts)
          :erlang.raise(kind, value, __STACKTRACE__)
      end
    end
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

  defp record_disposition({:ok, %Build{} = build}, _server, disposition, opts) do
    {:ok,
     %{
       build
       | builder_destroyed: disposition == :ok,
         builder_image: Keyword.get(opts, :builder_image, @builder_image)
     }}
  end

  # A failed build has a disposition too, and it is the one most worth having:
  # "the builder is destroyed even when the build fails" is exactly the claim
  # that rots quietly, because a failed deploy already looks like a failure and
  # a leaked box adds nothing visible to it.
  defp record_disposition({:error, reason}, server, disposition, opts) do
    {:error, reason,
     %{
       builder: server_name(server),
       builder_image: Keyword.get(opts, :builder_image, @builder_image),
       builder_destroyed: disposition == :ok
     }}
  end

  defp record_disposition(other, _server, _disposition, _opts), do: other

  defp builder_spec(architecture) do
    case Map.fetch(@builders, architecture) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_architecture, architecture}}
    end
  end

  # An explicit `:builder_image` always wins — a caller that already knows
  # which image it wants (a test, a drill, a caller mid-migration off this
  # entirely) is answering a question this has no business re-deciding.
  # Otherwise this is where `docker-ce` quietly becomes whichever custom
  # image `ensure_builder_image/3` finds or builds — `start_builder/4`
  # already reads `opts[:builder_image]` unconditionally, so nothing else
  # has to change to pick it up.
  #
  # Never fails the build. An account with no Hetzner token configured, or a
  # real provider error resolving the image, falls back to the stock image
  # and `Remote.ensure_kamal/1`'s own full install — slower, but the same
  # path that has worked all along. An optimization is not allowed to be the
  # reason a deploy that would otherwise have succeeded does not.
  defp with_builder_image(scope, architecture, opts) do
    if Keyword.has_key?(opts, :builder_image) do
      opts
    else
      case ensure_builder_image(scope, architecture, opts) do
        {:ok, image_id} -> Keyword.put(opts, :builder_image, image_id)
        {:error, _reason} -> opts
      end
    end
  end

  @doc """
  A builder image for `architecture` with kamal already on it — found by
  label if one already exists, built once if not.

  Every ordinary build used to pay `apt-get install ruby-full build-essential
  && gem install kamal` fresh, on the stock `docker-ce` image, every single
  time — 30-90s of apt-mirror-dependent work on every deploy, for a toolchain
  that never changes between builds. This is the box that stops paying it:
  built once from the same stock image and the same `Remote.ensure_kamal/1`
  every ordinary builder already runs, then kept and labelled so the next
  build finds it instead of re-paying the bootstrap.
  """
  @spec ensure_builder_image(Scope.t(), :arm | :x86, keyword()) ::
          {:ok, String.t() | integer()} | {:error, term()}
  def ensure_builder_image(%Scope{} = scope, architecture, opts \\ []) do
    list_images = Keyword.get(opts, :list_images, &Hetzner.list_images/2)
    selector = "#{@builder_image_label}=#{architecture}"

    case list_images.(scope, label_selector: selector, status: "available") do
      {:ok, [image | _]} -> {:ok, image["id"]}
      {:ok, []} -> build_builder_image(scope, architecture, opts)
      {:error, _reason} = error -> error
    end
  end

  # A temporary box, bootstrapped exactly like an ordinary builder, snapshot
  # and gone either way — the same "every path destroys" discipline
  # `build/3` itself follows, for the same reason: a box this leaves behind
  # is one nobody is watching on an invoice somebody pays.
  defp build_builder_image(scope, architecture, opts) do
    with {:ok, spec} <- builder_spec(architecture) do
      create = Keyword.get(opts, :create, &Hetzner.create_server/3)
      destroy = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)
      create_image = Keyword.get(opts, :create_image, &Hetzner.create_image/3)
      name = "cms-builder-bootstrap-#{architecture}-#{System.unique_integer([:positive])}"

      create_opts = [
        server_type: spec.server_type,
        location: Keyword.get(opts, :builder_location) || spec.location,
        image: @builder_image,
        ssh_key_ids: Keyword.get(opts, :ssh_key_ids),
        network_ids: Keyword.get(opts, :network_ids)
      ]

      Logger.warning(
        "[Builder] bootstrap create_opts location=#{inspect(create_opts[:location])} " <>
          "network_ids=#{inspect(create_opts[:network_ids])} spec.location=#{inspect(spec.location)}"
      )

      case create.(scope, name, create_opts) do
        {:ok, server} ->
          bootstrap_and_snapshot(scope, server, architecture, destroy, create_image, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  # The source server is not destroyed until the snapshot Hetzner is taking
  # *of* it is confirmed done. `create_image/3`'s own moduledoc says the
  # caller polls for the image to actually appear rather than trusting a
  # bare "accepted" response — this used to say that and not do it: the
  # image the initial response names is `status: "creating"`, and deleting
  # its source while Hetzner is still reading from it is exactly the timing
  # bug this discipline exists to close. `Builder.build/3`'s own "every path
  # destroys" only ever meant "eventually", not "before the thing being
  # destroyed still owes something to a request already in flight."
  defp bootstrap_and_snapshot(scope, server, architecture, destroy, create_image, opts) do
    run = Keyword.get(opts, :run) || Remote.ssh_runner(server, opts)
    attempts = Keyword.get(opts, :ssh_attempts, 90)
    list_images = Keyword.get(opts, :list_images, &Hetzner.list_images/2)

    result =
      with :ok <- Remote.await_ssh(run, attempts, opts),
           :ok <- Remote.ensure_kamal(run),
           :ok <- sync_disk(run),
           {:ok, %{"image" => image}} <-
             create_image.(scope, server_id(server),
               description: "CodeMySpec builder (#{architecture})",
               labels: %{@builder_image_label => to_string(architecture)}
             ),
           :ok <- await_image_ready(list_images, scope, image["id"], architecture, opts) do
        {:ok, image["id"]}
      end

    destroy_temp_server(destroy, scope, server, architecture)
    result
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
  # threaded into the return value, the same reason `Builder.destroy/3`
  # itself is best-effort: a cleanup failure must not turn a successful
  # image build into a failed one, but it must not vanish either.
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
  defp await_image_ready(list_images, scope, image_id, architecture, opts, attempts \\ 30)

  defp await_image_ready(_list_images, _scope, image_id, _architecture, _opts, 0) do
    {:error, {:image_not_ready, image_id}}
  end

  defp await_image_ready(list_images, scope, image_id, architecture, opts, attempts) do
    selector = "#{@builder_image_label}=#{architecture}"

    case list_images.(scope, label_selector: selector, status: "available") do
      {:ok, images} ->
        if Enum.any?(images, &(&1["id"] == image_id)) do
          :ok
        else
          Wait.sleep(Keyword.get(opts, :image_poll_interval_ms, 3_000))
          await_image_ready(list_images, scope, image_id, architecture, opts, attempts - 1)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp start_builder(scope, ref, spec, opts) do
    create = Keyword.get(opts, :create, &Hetzner.create_server/3)
    name = builder_name(ref)

    # `ssh_key_ids` is forwarded rather than dropped: `create_server/3` refuses
    # without one, and a builder nobody can log into cannot build anything.
    create_opts = [
      server_type: spec.server_type,
      # The app box's location when there is one. The builder pushes to a
      # registry on that box's private network, and a network's subnet lives in
      # exactly one zone — so a builder in another zone holds an address on a
      # network it cannot actually reach. It also means the image crosses a
      # datacenter instead of an ocean.
      location: Keyword.get(opts, :builder_location) || spec.location,
      image: Keyword.get(opts, :builder_image, @builder_image),
      ssh_key_ids: Keyword.get(opts, :ssh_key_ids),
      # The registry it pushes to answers on a private address, so the builder
      # has to be on that network. Attached at creation rather than after: the
      # reference it was handed names an address it would not yet hold.
      network_ids: Keyword.get(opts, :network_ids)
    ]

    Logger.warning(
      "[Builder] start_builder create_opts location=#{inspect(create_opts[:location])} " <>
        "network_ids=#{inspect(create_opts[:network_ids])} spec.location=#{inspect(spec.location)} " <>
        "opts[:builder_location]=#{inspect(Keyword.get(opts, :builder_location))} " <>
        "opts[:registry_host]=#{inspect(Keyword.get(opts, :registry_host))}"
    )

    case create.(scope, name, create_opts) do
      {:error, {:hetzner_error, 409, _}} ->
        reclaim_orphan(scope, name, create, create_opts, opts)

      {:error, {:hetzner_error, 403, %{"error" => %{"code" => "resource_limit_exceeded"}}}} =
          error ->
        reap_and_retry(scope, name, create, create_opts, opts, error)

      other ->
        other
    end
  end

  # A server-limit refusal reads as "the account is too small" (issue
  # 13ad1abe's whole point), when the true cause is often a `builder-*` box a
  # dead process never destroyed still holding a slot. Before surfacing that
  # error, clear anything that fits — named like a builder, older than
  # `@orphan_max_age_minutes` — and retry the create once.
  #
  # If nothing was old enough to reap, the shortage is real and the original
  # error is the honest answer; retrying would only ask Hetzner the same
  # question again. If something was reaped but the retry still fails —
  # Hetzner's delete is asynchronous, so the slot may not be free yet — that
  # retry's own error is what the caller sees, which is no worse than today.
  defp reap_and_retry(scope, name, create, create_opts, opts, error) do
    case reap_orphaned_builders(scope, opts) do
      [] -> error
      _reaped -> create.(scope, name, create_opts)
    end
  end

  # Age-based on purpose: it needs no cooperation from the process that
  # died, which is the one signal a SIGKILL, a killed `mix test`, or a
  # cancelled drill can never give.
  defp reap_orphaned_builders(scope, opts) do
    list = Keyword.get(opts, :list, &Hetzner.list_servers/1)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    destroy_server = Keyword.get(opts, :destroy, &Hetzner.delete_server/2)
    cutoff = DateTime.add(now.(), -@orphan_max_age_minutes * 60, :second)

    case list.(scope) do
      {:ok, servers} ->
        orphans = Enum.filter(servers, &stale_orphan?(&1, cutoff))
        Enum.each(orphans, &destroy_server.(scope, server_id(&1)))
        orphans

      _ ->
        []
    end
  end

  defp stale_orphan?(server, cutoff) do
    name = server_name(server) || ""
    String.starts_with?(name, @builder_prefix) and created_before?(server, cutoff)
  end

  # No timestamp is not evidence of age. The safe reading is "not old enough
  # to reap" — the mirror of `mix cms.provisioning_leaks`' own rule that no
  # timestamp reads as "recent" for the opposite question.
  defp created_before?(server, cutoff) do
    case DateTime.from_iso8601(to_string(server["created"] || "")) do
      {:ok, created, _} -> DateTime.compare(created, cutoff) == :lt
      _ -> false
    end
  end

  # The name is deterministic from `ref` (criterion: same commit always
  # builds on the same box name), so RunLock (project.id-keyed) rules out two
  # runs of *this* project racing each other onto it. It does not rule out
  # everything else the account can do to the same name: a different project
  # whose own ref happens to collide, a manual retry issued outside
  # `run_provisioning_step`, anything else with a Hetzner token for this
  # account. Confirmed live against MarketMySpec: a builder mid-deploy — SSH
  # reachable, image already pushed, migrate about to run against it — was
  # destroyed out from under a build that owned it, and there was no crash,
  # no kill, nothing RunLock would have seen, to explain it. The only honest
  # read left was that this destroyed it: unconditionally, on nothing but a
  # name match, with no check that the thing at that name was actually dead.
  #
  # `Hetzner.ensure_server/3` would adopt a same-named collision, and that is
  # right for a server meant to live for months. Adopting is wrong here — a
  # builder is single-use and destroyed at the end of every build specifically
  # so one customer's source never sits on a box that held another's (see
  # moduledoc) — but destroying on sight is just as wrong when the box is new
  # enough to plausibly still be somebody's live build. `stale_orphan?`'s own
  # age threshold is the line already drawn elsewhere in this module between
  # "abandoned" and "still running" (see `reap_orphaned_builders/2`); this is
  # the same line, so a name collision destroys only what age already marks a
  # crash, a kill, or an MCP transport timeout (issue faaf76b6) — and refuses,
  # loud, rather than kill something too young to be one of those.
  defp reclaim_orphan(scope, name, create, create_opts, opts) do
    find = Keyword.get(opts, :find, &Hetzner.find_server/2)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now.(), -@orphan_max_age_minutes * 60, :second)

    case find.(scope, name) do
      {:ok, orphan} ->
        reclaim_if_stale(scope, orphan, cutoff, name, create, create_opts, opts)

      {:error, :not_found} ->
        # Destroyed between the 409 and this lookup — by another cleanup, or
        # a server the API hasn't listed yet. Either way the retry is the
        # caller's best shot, not a second special case.
        create.(scope, name, create_opts)

      {:error, reason} ->
        {:error,
         {:orphaned_builder,
          "A builder named #{name} already exists at Hetzner, left over from an earlier " <>
            "interrupted run, but looking it up to clear it failed: #{inspect(reason)}."}}
    end
  end

  defp reclaim_if_stale(scope, orphan, cutoff, name, create, create_opts, opts) do
    if created_before?(orphan, cutoff) do
      case destroy(scope, orphan, opts) do
        :ok -> create.(scope, name, create_opts)
        other -> orphan_undestroyable_error(name, other)
      end
    else
      too_young_to_reclaim_error(name)
    end
  end

  defp too_young_to_reclaim_error(name) do
    {:error,
     {:orphaned_builder,
      "A builder named #{name} already exists at Hetzner and is too recent to be an " <>
        "abandoned run — most likely a live build using it right now. Refusing to destroy " <>
        "it; retry once that build finishes."}}
  end

  defp orphan_undestroyable_error(name, reason) do
    {:error,
     {:orphaned_builder,
      "A builder named #{name} already exists at Hetzner, left over from an earlier " <>
        "interrupted run, and could not be removed to make way for this one: " <>
        "#{inspect(reason)}. Delete it manually at Hetzner and re-run."}}
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

  # Best effort, and deliberately not part of the return. A failure to destroy
  # is worth knowing about, but it must not turn a successful build into a
  # failed one — the image exists either way, and the leak is what the audit
  # is for.
  defp destroy(scope, server, opts) do
    case Keyword.get(opts, :destroy, &Hetzner.delete_server/2).(scope, server_id(server)) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp builder_name(ref), do: @builder_prefix <> String.slice(ref, 0, 12)

  defp server_id(%{"id" => id}), do: id
  defp server_id(%{"server" => %{"id" => id}}), do: id

  defp server_name(%{"name" => name}), do: name
  defp server_name(%{"server" => %{"name" => name}}), do: name
  defp server_name(_), do: nil
end
