defmodule CodeMySpec.Provisioning.Builder.Remote do
  @moduledoc """
  Run the build on the builder box.

  Separate from `Builder` because they answer different questions. `Builder`
  owns the box's existence — created for one build, destroyed either way.
  This owns what happens while it exists: reach it, fetch the commit, build,
  push, and read back what was actually built.

  That last step is the one worth defending. `Builder` refuses to publish an
  image whose architecture is not the one the servers run, and that check is
  worth nothing if this simply echoes back the architecture it was asked for.
  So the architecture is read off the built image, and a build that quietly
  produced the wrong one is caught by the check rather than waved through it.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.Wait

  # A freshly created box answers the API long before it answers SSH. Polled
  # rather than slept-through, so a box that comes up quickly is not waited on
  # for the worst case.
  @ssh_attempts 30
  @ssh_interval_ms 2_000

  @doc """
  Build `ref` on `server` and push it to `reference`.

  `:run` takes the whole command as a list and returns `{output, status}`,
  which is what makes this testable without a box: the commands are the
  interesting part, and running them is not.
  """
  @spec build(map(), String.t(), String.t(), keyword()) ::
          {:ok, %{reference: String.t(), architecture: :arm | :x86}} | {:error, term()}
  def build(server, ref, reference, opts \\ []) do
    run = Keyword.get(opts, :run) || ssh_runner(server, opts)
    repo = Keyword.fetch!(opts, :repository_url)

    with :ok <- await_ssh(run, Keyword.get(opts, :ssh_attempts, @ssh_attempts), opts),
         :ok <- fetch(run, repo, ref),
         :ok <- docker_build(run, reference, ref),
         :ok <- docker_push(run, reference),
         {:ok, architecture} <- built_architecture(run, reference) do
      {:ok, %{reference: reference, architecture: architecture}}
    end
  end

  # Reachability, not readiness of anything in particular: if `true` runs, the
  # box is up and the key works, which is the whole precondition.
  defp await_ssh(_run, 0, _opts), do: {:error, :builder_unreachable}

  defp await_ssh(run, attempts, opts) do
    case run.(["true"]) do
      {_, 0} ->
        :ok

      _ ->
        Wait.sleep(Keyword.get(opts, :ssh_interval_ms, @ssh_interval_ms))
        await_ssh(run, attempts - 1, opts)
    end
  end

  # A shallow fetch of one commit. The builder does not need the history, and
  # a full clone of a long-lived repository is the difference between a build
  # that starts now and one that starts in a minute.
  defp fetch(run, repo, ref) do
    case run.(["rm -rf /build && mkdir -p /build && cd /build && git init -q && " <>
                 "git remote add origin #{repo} && git fetch -q --depth 1 origin #{ref} && " <>
                 "git checkout -q FETCH_HEAD"]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:fetch_failed, status, trim(output)}}
    end
  end

  defp docker_build(run, reference, ref) do
    case run.(["cd /build && docker build --label commit=#{ref} -t #{reference} ."]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:build_failed, status, trim(output)}}
    end
  end

  defp docker_push(run, reference) do
    case run.(["docker push #{reference}"]) do
      {_, 0} -> :ok
      {output, status} -> {:error, {:push_failed, status, trim(output)}}
    end
  end

  # Read, not assumed. `Builder` refuses to ship an image built for the wrong
  # architecture, and that refusal only means something if this reports what
  # the image actually is.
  defp built_architecture(run, reference) do
    case run.(["docker image inspect --format '{{.Architecture}}' #{reference}"]) do
      {output, 0} -> architecture(trim(output))
      {output, status} -> {:error, {:inspect_failed, status, trim(output)}}
    end
  end

  defp architecture("arm64"), do: {:ok, :arm}
  defp architecture("aarch64"), do: {:ok, :arm}
  defp architecture("amd64"), do: {:ok, :x86}
  defp architecture("x86_64"), do: {:ok, :x86}
  defp architecture(other), do: {:error, {:unknown_architecture, other}}

  # One SSH invocation per command, which is slower than holding a session open
  # and much easier to reason about: every command is independently visible in
  # a log and independently replaceable in a test.
  defp ssh_runner(server, opts) do
    env = Keyword.fetch!(opts, :env)
    key = Keyword.fetch!(opts, :ssh_key_path)
    host = ip(server)

    fn [command] ->
      Environments.cmd(
        env,
        "ssh",
        [
          "-o",
          "StrictHostKeyChecking=no",
          "-o",
          "UserKnownHostsFile=/dev/null",
          "-i",
          key,
          "root@#{host}",
          command
        ],
        stderr_to_stdout: true
      )
    end
  end

  defp ip(%{"public_net" => %{"ipv4" => %{"ip" => ip}}}), do: ip
  defp ip(%{"server" => server}), do: ip(server)
  defp ip(%{"ip" => ip}), do: ip

  defp trim(output), do: output |> to_string() |> String.trim()
end
