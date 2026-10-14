defmodule CodeMySpec.Release.HarnessOnnxruntimeTest do
  use ExUnit.Case, async: true

  setup do
    root = Path.join(System.tmp_dir!(), "harness-ort-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "erts-15.2/bin")
    native = Path.join(root, "lib/ortex-0.1.10/priv/native")
    File.mkdir_p!(bin)
    File.mkdir_p!(native)
    File.write!(Path.join(bin, "erl.exe"), "fixture executable")
    on_exit(fn -> File.rm_rf!(root) end)
    %{release: %{path: root}, bin: bin, native: native}
  end

  test "Windows packages the bundled runtime and companion DLL beside erl.exe", ctx do
    File.write!(Path.join(ctx.native, "onnxruntime.dll"), "bundled ORT 1.19.2")
    File.write!(Path.join(ctx.native, "onnxruntime_providers_shared.dll"), "bundled provider")
    File.write!(Path.join(ctx.bin, "onnxruntime.dll"), "older runtime")

    assert CodeMySpec.MixProject.copy_onnxruntime_dll(ctx.release, {:win32, :nt}) == ctx.release
    assert File.read!(Path.join(ctx.bin, "onnxruntime.dll")) == "bundled ORT 1.19.2"

    assert File.read!(Path.join(ctx.bin, "onnxruntime_providers_shared.dll")) ==
             "bundled provider"

    assert File.read!(Path.join(ctx.native, "onnxruntime.dll")) == "bundled ORT 1.19.2"
  end

  test "Windows refuses a release with no bundled runtime", ctx do
    assert_raise Mix.Error, ~r/Missing bundled onnxruntime.dll/, fn ->
      CodeMySpec.MixProject.copy_onnxruntime_dll(ctx.release, {:win32, :nt})
    end
  end

  test "a companion DLL alone cannot satisfy the runtime requirement", ctx do
    File.write!(Path.join(ctx.native, "onnxruntime_providers_shared.dll"), "provider only")

    assert_raise Mix.Error, ~r/Missing bundled onnxruntime.dll/, fn ->
      CodeMySpec.MixProject.copy_onnxruntime_dll(ctx.release, {:win32, :nt})
    end

    refute File.exists?(Path.join(ctx.bin, "onnxruntime_providers_shared.dll"))
  end

  test "Windows refuses an ambiguous ERTS destination", ctx do
    File.mkdir_p!(Path.join(ctx.release.path, "erts-other/bin"))

    assert_raise Mix.Error, ~r/Expected one bundled ERTS/, fn ->
      CodeMySpec.MixProject.copy_onnxruntime_dll(ctx.release, {:win32, :nt})
    end
  end

  test "non-Windows releases require no Windows runtime", ctx do
    assert CodeMySpec.MixProject.copy_onnxruntime_dll(ctx.release, {:unix, :darwin}) ==
             ctx.release

    assert CodeMySpec.MixProject.copy_onnxruntime_dll(ctx.release, {:unix, :linux}) == ctx.release
    assert File.ls!(ctx.bin) == ["erl.exe"]
  end
end
