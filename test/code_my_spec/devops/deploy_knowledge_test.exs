defmodule CodeMySpec.Devops.DeployKnowledgeTest do
  use ExUnit.Case, async: true

  @devops_path "priv/knowledge/devops"

  test "current deploy guidance names the burst box and private registry" do
    readme = File.read!(Path.join(@devops_path, "README.md"))
    deploy = File.read!(Path.join(@devops_path, "hetzner-docker-deploy.md"))

    for document <- [readme, deploy] do
      assert document =~ "Provisioning.Builder"
      assert document =~ "private"
      assert document =~ "migrate"
      refute document =~ "gh run watch"
      refute document =~ "kamal deploy --skip-push"
    end

    refute File.exists?(Path.join(@devops_path, "ci-image-build.md"))
  end

  test "Dockerfile build gotchas remain available after retiring the CI guide" do
    deploy = File.read!(Path.join(@devops_path, "hetzner-docker-deploy.md"))

    assert deploy =~ "touch envs/.env envs/prod.env"
    assert deploy =~ "mix assets.deploy"
    assert deploy =~ "TARGETARCH"
  end
end
