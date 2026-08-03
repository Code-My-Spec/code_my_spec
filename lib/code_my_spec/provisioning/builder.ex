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

  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  defmodule Build do
    @moduledoc "What a finished build produced, and what it cost."

    @type t :: %__MODULE__{
            image: String.t(),
            architecture: :arm | :x86,
            builder: String.t(),
            built_at: DateTime.t()
          }

    defstruct [:image, :architecture, :builder, :built_at]
  end

  # Hetzner's two lines, and the box each architecture builds on. A build has
  # to happen on the architecture it will run on: an image built for the other
  # one fails at container start, which is a deploy that looks healthy right up
  # until the swap.
  @builders %{
    arm: %{server_type: "cax11", location: "fsn1"},
    x86: %{server_type: "cpx11", location: "ash"}
  }

  @doc """
  Build `ref` for `architecture`, and take the builder with it either way.

  `:build` is injectable because a container build is a bad thing to record —
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
      # `after`, not a happy-path cleanup: a builder outlives a raise, a
      # non-zero exit and an early return alike, and each of those leaves a box
      # nobody is watching on an invoice somebody is paying.
      try do
        run(scope, server, ref, architecture, opts)
      after
        destroy(scope, server, opts)
      end
    end
  end

  defp builder_spec(architecture) do
    case Map.fetch(@builders, architecture) do
      {:ok, spec} -> {:ok, spec}
      :error -> {:error, {:unknown_architecture, architecture}}
    end
  end

  defp start_builder(scope, ref, spec, opts) do
    create = Keyword.get(opts, :create, &Hetzner.create_server/3)

    create.(scope, builder_name(ref), [
      server_type: spec.server_type,
      location: spec.location,
      # The pre-warmed image, so a deploy does not pay for the toolchain every
      # time. Falls back to a plain OS image, which still builds — just slowly.
      image: Keyword.get(opts, :builder_image, "ubuntu-24.04")
    ])
  end

  defp run(scope, server, ref, architecture, opts) do
    build_fun = Keyword.get(opts, :build, &docker_build/4)
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

  defp docker_build(_scope, _server, _ref, _architecture),
    do: {:error, :build_not_configured}

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
