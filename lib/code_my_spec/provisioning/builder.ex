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

  alias CodeMySpec.Provisioning.Builder.Remote
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  defmodule Build do
    @moduledoc "What a finished build produced, and what it cost."

    @type t :: %__MODULE__{
            image: String.t(),
            architecture: :arm | :x86,
            builder: String.t(),
            builder_image: String.t(),
            builder_destroyed: boolean(),
            built_at: DateTime.t()
          }

    defstruct [:image, :architecture, :builder, :builder_image, :builder_destroyed, :built_at]
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
         {:ok, server} <- start_builder(scope, ref, spec, opts) do
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

    case create.(scope, name, create_opts) do
      {:error, {:hetzner_error, 409, _}} -> reclaim_orphan(scope, name, create, create_opts, opts)
      other -> other
    end
  end

  # The name is deterministic from `ref` (criterion: same commit always
  # builds on the same box name), so a collision here is not two callers
  # racing — RunLock already serializes runs per project — it is a box an
  # earlier run created and never reached `destroy/3` for: a crash, a kill, an
  # MCP transport timeout (issue faaf76b6).
  #
  # `Hetzner.ensure_server/3` would adopt a same-named collision, and that is
  # right for a server meant to live for months. It is wrong here: a builder
  # is single-use and destroyed at the end of every build specifically so one
  # customer's source never sits on a box that held another's (see
  # moduledoc). A box that survived to collide is not a peer to build on top
  # of — it may hold a half-finished push or a docker daemon left mid-crash
  # from whatever killed the run that made it. So this clears the orphan and
  # retries the create once, rather than adopting.
  defp reclaim_orphan(scope, name, create, create_opts, opts) do
    find = Keyword.get(opts, :find, &Hetzner.find_server/2)

    case find.(scope, name) do
      {:ok, orphan} ->
        case destroy(scope, orphan, opts) do
          :ok -> create.(scope, name, create_opts)
          other -> orphan_undestroyable_error(name, other)
        end

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
    build_fun = Keyword.get(opts, :build_fun, fn scope, server, ref, architecture ->
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
         built_at: now.()
       }}
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
  defp docker_build(_scope, server, ref, _architecture, opts) do
    case Keyword.get(opts, :reference) do
      nil ->
        {:error, :no_image_reference}

      reference ->
        Remote.build(server, ref, reference, opts)
    end
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

  defp builder_name(ref), do: "builder-" <> String.slice(ref, 0, 12)

  defp server_id(%{"id" => id}), do: id
  defp server_id(%{"server" => %{"id" => id}}), do: id

  defp server_name(%{"name" => name}), do: name
  defp server_name(%{"server" => %{"name" => name}}), do: name
  defp server_name(_), do: nil
end
