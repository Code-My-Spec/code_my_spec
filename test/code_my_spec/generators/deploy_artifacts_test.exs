defmodule CodeMySpec.Generators.DeployArtifactsTest do
  @moduledoc """
  What a generated project has to carry before it can deploy at all.

  Every assertion here stands for a failure seen on a real box. The release
  reads `DATABASE_URL` and `SECRET_KEY_BASE` from its environment in
  `runtime.exs`, and the only place they exist is inside
  `envs/<env>.enc.env` — so each path that starts the release has to decrypt
  first, and the image has to carry both the ciphertext and the tool.

  Missing any one of them fails the same way and reads as something else:
  the app raises "environment variable DATABASE_URL is missing", kamal waits
  out its 30s health timeout, and the deploy reports a failed traffic swap —
  naming the swap, which was not the thing that was wrong.

  `boot` and `migrate` are asserted separately on purpose. They drifted apart
  once: the decryption was written for the serving path and `migrate` was
  left running the release raw, so every migration died and no generated
  project could complete a deploy.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Generators.DeployArtifacts

  @opts [app: "my_app", host: "example.com", registry: "ghcr.io", owner: "acme"]

  defp file(path) do
    {^path, body} = Enum.find(DeployArtifacts.files(@opts), &(elem(&1, 0) == path))
    body
  end

  describe "the release overlays" do
    test "boot decrypts the environment before starting the app" do
      body = file("rel/overlays/bin/boot")

      assert body =~ ~s(exec sops exec-env "$ENV_FILE" "./bin/my_app start")
      assert body =~ ~s(ENV_FILE="envs/${ENV_NAME}.enc.env")
    end

    test "migrate decrypts the environment before running migrations" do
      body = file("rel/overlays/bin/migrate")

      assert body =~ ~s(exec sops exec-env "$ENV_FILE" "./bin/my_app eval MyApp.Release.migrate")
      assert body =~ ~s(ENV_FILE="envs/${ENV_NAME}.enc.env")
    end

    test "both name a missing key and a missing env file rather than letting sops answer" do
      # sops fails an absent key with "no identity matched any of the
      # recipients", which reads as the file being encrypted to somebody else.
      for path <- ["rel/overlays/bin/boot", "rel/overlays/bin/migrate"] do
        body = file(path)

        assert body =~ ~s(if [ -z "${SOPS_AGE_KEY:-}" ]; then), path
        assert body =~ ~s(if [ ! -f "$ENV_FILE" ]; then), path
      end
    end

    test "both take the environment from APP_ENV, so one image serves either" do
      for path <- ["rel/overlays/bin/boot", "rel/overlays/bin/migrate"] do
        assert file(path) =~ ~s(ENV_NAME="${APP_ENV:-prod}"), path
      end
    end
  end

  describe "the Dockerfile" do
    test "starts the app through boot, not through the release directly" do
      assert file("Dockerfile") =~ ~s(CMD ["bin/boot"])
      refute file("Dockerfile") =~ ~s(CMD ["bin/my_app", "start"])
    end

    test "carries the encrypted environments into the image" do
      assert file("Dockerfile") =~ "COPY envs rel/overlays/envs"
    end

    test "carries sops into the runtime stage, fetched in the builder" do
      body = file("Dockerfile")

      assert body =~ "COPY --from=builder /usr/local/bin/sops /usr/local/bin/sops"
      assert body =~ "sops-v${SOPS_VERSION}.linux.$(dpkg --print-architecture)"
    end
  end

  describe "the runtime config" do
    test "excludes the health path by path, not by hostname" do
      # `Plug.SSL.validate_exclude!/1` maps a bare binary to `{:hosts, [binary]}`,
      # so `exclude: ["/health"]` excluded a host named "/health" — which matches
      # nothing, leaving the proxy's probe redirected and the swap never done.
      body = file("config/runtime.exs")

      assert body =~ ~s(paths: ["/health"])
      assert body =~ ~s(hosts: ["localhost", "127.0.0.1"])
    end
  end
end
