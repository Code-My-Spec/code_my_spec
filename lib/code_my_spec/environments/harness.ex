defmodule CodeMySpec.Environments.Harness do
  @moduledoc """
  A working copy on someone else's machine, reached over its harness channel.

  ## Why this exists

  The light harness server holds no working copy, so `scope.environment` was
  `nil` there and every file operation returned `{:error, :no_environment}`.
  That answer is a lie in a specific and damaging way: the project *has* a
  working copy, it is simply not on this machine. Saying "no environment" says
  "no such thing", and 48 server-side modules — 19 of them agent tasks whose
  evaluators run on the server — then did the wrong thing with it:

    * `ComponentSync` could not read a spec and dropped the component; a full
      sync deleted it for being absent (684f072e).
    * `ArchitectureDesign`'s evaluator could not read the proposal it was
      judging and took the whole stop gate down (074b7c83).
    * `create_component` could not write a spec stub and told agents the server
      "has no working copy", which reads as a limitation rather than a bug
      (35e309b9).

  Each was reported separately. They are one thing.

  ## The shape

  Operations travel to the harness and are performed there, on the disk that
  actually holds the checkout. Reads and writes both: a spec stub has to be
  written where the working copy is, and no amount of server-side cleverness
  changes that.

  Addressed by harness id rather than path, carried in `ref`, because two
  checkouts of one project are two working copies and a path cannot tell them
  apart — the same reason the hook surface is id-addressed.

  ## What it costs, stated plainly

  Every call is a round trip. That is fine for the cases this exists for — an
  evaluator reading one artifact, a tool writing one stub — and wrong for bulk:
  `ComponentSync` reading 1,500 specs this way would be 1,500 round trips, which
  is why the scanner parses on the device and ships the verdict in the manifest
  instead. Prefer the manifest where one exists; use this where the server
  genuinely has to touch a file.

  A harness that is not connected returns `{:error, {tag, details}}` — distinct
  from `:no_environment` on purpose. That means "there is no working copy";
  these mean "there is, and I cannot reach it right now", with the tag saying
  why (see `Analysis.harness_fs_request/4` for the transport's tags; this
  module adds `:harness_not_configured` and `:harness_no_id`, both of which are
  wiring bugs rather than states). Callers
  that prune, delete or report absence must treat them differently.
  """

  @behaviour CodeMySpec.Environments.EnvironmentsBehaviour

  require Logger

  alias CodeMySpec.Environments.Environment

  # Generous: the far side is doing local disk work, not computation. Long
  # enough to survive a harness that is briefly busy, short enough that a
  # dead one does not hold a request open.
  @timeout :timer.seconds(30)

  @impl true
  def read_file(%Environment{} = env, path), do: request(env, "read_file", %{"path" => path})

  @impl true
  def write_file(%Environment{} = env, path, content),
    do: request(env, "write_file", %{"path" => path, "content" => content})

  @impl true
  def delete_file(%Environment{} = env, path), do: request(env, "delete_file", %{"path" => path})

  @impl true
  def list_directory(%Environment{} = env, path),
    do: request(env, "list_directory", %{"path" => path})

  @impl true
  def ensure_dir(%Environment{} = env, path), do: request(env, "ensure_dir", %{"path" => path})

  @impl true
  def stat(%Environment{} = env, path), do: request(env, "stat", %{"path" => path})

  # Booleans, because the behaviour says so. An unreachable harness answers
  # `false` — the same answer a missing file gives, which is the one place this
  # module cannot keep the two apart. Callers needing the distinction should use
  # `stat/2`, which returns a tuple.
  #
  # Listing is the second half rather than an optimisation: `stat` answers only
  # for regular files (a directory comes back `{:error, :not_regular}`), while
  # the other four implementations answer `true` for a directory — `File.exists?`
  # twice, `test -e`, and prefix membership. Asking `stat` alone made this the
  # one backend where an existing directory reported missing, which is what hid
  # `.code_my_spec/knowledge` from the project knowledge library in production
  # while every in-memory test passed.
  @impl true
  def file_exists?(%Environment{} = env, path) do
    match?({:ok, _}, request(env, "stat", %{"path" => path})) or
      match?({:ok, _}, request(env, "list_directory", %{"path" => path}))
  end

  @impl true
  def glob(%Environment{} = env, pattern) do
    case request(env, "glob", %{"pattern" => pattern}) do
      {:ok, paths} when is_list(paths) -> paths
      _ -> []
    end
  end

  # Not proxied. `cmd` already has a route — `analysis/run` on the harness,
  # which owns the run ledger, single-flight and `_build` — and a second way to
  # run a command there would drift from it. `stream_files` is the manifest's
  # job, and `create`/`destroy` describe a lifecycle a harness does not have:
  # it exists because someone started it.
  @impl true
  def cmd(_env, _command, _args, _opts), do: {:error, :not_supported_on_harness}

  @impl true
  def stream_files(_env, _roots, _opts), do: {:error, :not_supported_on_harness}

  @impl true
  def create(_opts), do: {:error, :not_supported_on_harness}

  @impl true
  def destroy(_env), do: {:error, :not_supported_on_harness}

  @impl true
  def exec_file_exists?(_env, _path), do: false

  # Setup and teardown commands describe provisioning a sandbox. A harness is
  # not one — it is a developer's checkout that already exists — so these have
  # no meaning here rather than an empty implementation waiting to be filled in.
  @impl true
  def environment_setup_command(_env, _attrs), do: ""

  @impl true
  def code_environment_teardown_command(_env, _attrs), do: ""

  @impl true
  def docs_environment_teardown_command(_env, _attrs), do: ""

  @impl true
  def test_environment_teardown_command(_env, _attrs), do: ""

  defp request(%Environment{ref: %{"harness_id" => id}}, op, payload) when is_binary(id) do
    case Application.get_env(:code_my_spec, :harness_fs_transport) do
      nil ->
        # No transport configured is the harness binary's own case: it links
        # `Environments` and has no channel to reach anything over. Nothing
        # there should be building a `:harness` environment, so this is a wiring
        # bug rather than a state, and it says so rather than crashing.
        Logger.warning("[Environments.Harness] #{op} with no :harness_fs_transport configured")
        {:error, {:harness_not_configured, %{op: op}}}

      transport ->
        transport.harness_fs_request(id, op, payload, @timeout)
    end
  end

  defp request(%Environment{ref: ref}, op, _payload) do
    Logger.warning(
      "[Environments.Harness] #{op} on an environment with no harness id (ref: #{inspect(ref)})"
    )

    {:error, {:harness_no_id, %{op: op, ref: ref}}}
  end
end
