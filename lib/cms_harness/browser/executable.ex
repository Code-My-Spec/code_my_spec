defmodule CmsHarness.Browser.Executable do
  @moduledoc """
  The vibium binary to launch, rather than the Node script in front of it.

  `vibium` on PATH is an npm bin: a `#!/usr/bin/env node` script that finds
  `@vibium/<platform>-<arch>/bin/vibium` and runs it with `execFileSync`,
  blocking for the binary's whole life. So every copy's browser session was a
  Node process (~40 MB) holding open a Go one (~13 MB): 18 copies were 37
  processes and 920 MB on 2026-09-29. Launched directly, the binary answers
  `initialize` and `tools/list` identically. The script's `argv0: 'vibium'`
  only changes the name in `--help` text, and the binary's basename is already
  `vibium`.

  Resolved once per boot and kept in `:persistent_term`: PATH is runtime, and
  the answer does not change under a running harness. Absence is not kept, so
  installing vibium later is still seen.
  """

  require Logger

  @key {__MODULE__, :path}

  @typedoc "A host in Node's terms: `os.platform()` and the script's arch."
  @type host :: %{os: String.t(), arch: String.t()}

  @doc "The vibium to launch on this machine, or nil when it has none."
  @spec find() :: String.t() | nil
  def find do
    case :persistent_term.get(@key, nil) do
      nil -> find_now()
      path -> path
    end
  end

  defp find_now do
    case System.find_executable("vibium") do
      nil ->
        nil

      shim ->
        path = resolve(shim, host())
        log(shim, path)
        :persistent_term.put(@key, path)
        path
    end
  end

  defp log(shim, shim),
    do: Logger.info("[CmsHarness] browser: no vibium binary beside #{shim}, launching it as is")

  defp log(shim, path),
    do: Logger.info("[CmsHarness] browser: launching #{path} directly rather than via #{shim}")

  @doc """
  The platform binary the npm shim at `shim` would run, or `shim` itself.

  Looks where npm puts it, for the script's own package: nested under it, or
  hoisted beside it. The package is found by following the shim's symlink
  (`<prefix>/bin/vibium -> ../lib/node_modules/vibium/bin/cli.js`), or, where
  there is no symlink, at `<dir>/node_modules/vibium` (Windows, where
  `vibium.cmd` sits in the prefix) and `<dir>/../lib/node_modules/vibium`.
  """
  @spec resolve(String.t() | nil, host()) :: String.t() | nil
  def resolve(nil, _host), do: nil

  def resolve(shim, host) do
    dir = Path.dirname(shim)

    [
      shim |> follow(16) |> Path.dirname() |> Path.dirname(),
      Path.join(dir, "node_modules/vibium"),
      Path.join(dir, "../lib/node_modules/vibium")
    ]
    |> Enum.flat_map(&candidates(&1, host))
    |> Enum.find(shim, &File.regular?/1)
  end

  defp candidates(package, %{os: os, arch: arch}) do
    rel = Path.join(["@vibium", "#{os}-#{arch}", "bin", binary_name(os)])

    [
      Path.expand(Path.join([package, "node_modules", rel])),
      Path.expand(Path.join([package, "..", rel]))
    ]
  end

  defp binary_name("win32"), do: "vibium.exe"
  defp binary_name(_os), do: "vibium"

  defp follow(path, 0), do: path

  defp follow(path, hops) do
    case :file.read_link(path) do
      {:ok, target} -> follow(Path.expand(to_string(target), Path.dirname(path)), hops - 1)
      {:error, _} -> path
    end
  end

  @doc "This machine in Node's terms, which is how the platform package is named."
  @spec host() :: host()
  def host do
    case :os.type() do
      {:win32, _} ->
        %{os: "win32", arch: arch(System.get_env("PROCESSOR_ARCHITECTURE", ""))}

      {:unix, os} ->
        %{os: to_string(os), arch: arch(to_string(:erlang.system_info(:system_architecture)))}
    end
  end

  # The script maps x64 to x64 and everything else to arm64.
  defp arch(name) do
    if String.match?(name, ~r/^(x86_64|amd64)/i), do: "x64", else: "arm64"
  end
end
