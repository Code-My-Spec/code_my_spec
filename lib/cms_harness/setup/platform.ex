defmodule CmsHarness.Setup.Platform do
  @moduledoc """
  The machine `CmsHarness.Setup` is readying: its OS and CPU architecture.

  Detected once at the edge (the desktop bootstrap and the `check_prerequisites`
  LiveView handler) and passed into `Setup`/`Prerequisites` as a value, never
  read from inside them directly -- so what a step installs for is an input,
  not something a spec has to literally run on. `detect/0`'s override is the
  test-only seam for that input (see `CodeMySpecSpex.DesktopSetupHelpers.as_platform/3`).
  """

  @type os :: :windows | :darwin | :linux
  @type arch :: :x86_64 | :aarch64 | :unknown

  @type t :: %__MODULE__{os: os(), arch: arch()}

  @enforce_keys [:os, :arch]
  defstruct [:os, :arch]

  @doc """
  This machine's platform: the real one, or a spec's override.

  `Application.get_env(:code_my_spec, :setup_platform_override)` is read
  first -- a spec sets it (`DesktopSetupHelpers.as_platform/3`) to drive a
  platform this process is not actually running on. Production never sets
  it, so `:os.type/0` and the system architecture decide there.
  """
  @spec detect() :: t()
  def detect do
    case Application.get_env(:code_my_spec, :setup_platform_override) do
      %{os: os, arch: arch} -> %__MODULE__{os: os, arch: arch}
      _ -> %__MODULE__{os: detect_os(), arch: detect_arch()}
    end
  end

  defp detect_os do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :darwin} -> :darwin
      {:unix, _} -> :linux
    end
  end

  defp detect_arch do
    architecture = :erlang.system_info(:system_architecture) |> to_string()

    cond do
      architecture =~ ~r/aarch64|arm64/ -> :aarch64
      architecture =~ ~r/x86_64|amd64/ -> :x86_64
      true -> :unknown
    end
  end
end
