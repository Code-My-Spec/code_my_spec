defmodule CodeMySpec.Provisioning.DeployConfigParseTest do
  @moduledoc """
  kamal's config is ERB before it is YAML, and a plain YAML parse of one fails.

  A kamal config can carry both an ERB conditional at the start of a line
  followed by a real key, and an output tag containing double quotes inside a
  double-quoted value:

      <% if ENV["CMS_SSH_KEY_PATH"] %>  keys_only: true
      keys: [ "<%= ENV["CMS_SSH_KEY_PATH"] %>" ]

  YAML rejects the first outright and mis-parses the second. So every parse of
  such a config failed — and `config_targets_this_project/2` answers a failed
  parse with `:ok`, which meant the check that setup will not deploy to a host
  the project does not own had never run on a real config. It looked like a
  passing check and was an unparsed file.

  ## What this file does and does not show

  It pins the **parser** against the ERB shapes it has to tolerate. The fixture
  below is hand-written and was labelled "verbatim from a generated config",
  which it is not and has not been for some time: today's `kamal_config/5` bakes
  `host:` as a concrete string at generation time rather than leaving an ERB tag
  to resolve when kamal runs, emits no `user: root`, and supports no
  `CMS_SSH_PORT` (`55498802`).

  The fixture still earns its place — configs generated before that change carry
  these shapes, and so do hand-written ones like MarketMySpec's, and the parser
  has to read them. What it cannot do is what its label claimed: show that the
  current generator produces something this parser can read.

  That is a separate assertion and it has its own file now,
  `AGeneratedConfigActuallyParsesTest`, which calls `DeployArtifacts.files/1`
  and parses the real output. Keeping them apart is the point: a fixture that
  claims to be generator output silently stops being a check on the generator
  the moment the generator moves, and nothing fails.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Steps

  # The two shapes that break a plain YAML parse. Hand-written, and deliberately
  # broader than any one generator's output — it carries the ERB host tag and
  # `CMS_SSH_PORT` block that `kamal_config/5` no longer emits, because configs
  # in the wild still have them. Named for what it is rather than `@generated`:
  # the old name asserted a provenance it did not have, and a reader who
  # believed it would take this file as proof the generator is covered.
  @tolerated """
  service: myapp-uat
  image: <%= ENV["CMS_IMAGE_REPO"] || "myapp" %>

  servers:
    web:
      hosts:
        - <%= ENV["CMS_DEPLOY_HOST_IP"] || "<UAT_HOST_IP>" %>

  proxy:
    ssl: true
    host: <%= ENV["CMS_DEPLOY_HOST"] || "<UAT_HOST>" %>

  ssh:
    user: root
  <% if ENV["CMS_SSH_KEY_PATH"] %>  keys_only: true
    keys: [ "<%= ENV["CMS_SSH_KEY_PATH"] %>" ]
  <% end %>
  <% if ENV["CMS_SSH_PORT"] %>  # a comment inside the conditional
    port: <%= ENV["CMS_SSH_PORT"] %>
  <% end %>
  """

  test "an ERB-bearing config parses, and its service is readable" do
    assert {:ok, config} = Steps.parse_deploy_config(@tolerated)
    assert config["service"] == "myapp-uat"
  end

  # `resolved_at_runtime?/1` recognises a host by the `<%` in it, so the tag
  # has to survive the rewrite — a parser that dropped it would make every
  # generated config look like it named a literal hostname.
  test "an output tag survives, so the host still reads as runtime-resolved" do
    {:ok, config} = Steps.parse_deploy_config(@tolerated)

    assert config["proxy"]["host"] =~ "<%"
    assert config["proxy"]["host"] =~ "CMS_DEPLOY_HOST"
  end

  test "the conditional key is kept rather than dropped with its tag" do
    {:ok, config} = Steps.parse_deploy_config(@tolerated)

    assert config["ssh"]["keys_only"] == true,
           "the key after the ERB conditional was thrown away with the tag"
  end

  # The SSH port block is the same shape as the key block but with a comment
  # where the first block has a key, which is the case that would have snuck
  # past: stripping the tag leaves a bare comment line, and a stripper that
  # mishandled it would take the `port:` line with it — or fail the whole parse,
  # which `config_targets_this_project/2` answers with `:ok`. That is how the
  # host-ownership check came to have never run on a real config.
  test "the ssh port block parses, tag stripped and value kept" do
    {:ok, config} = Steps.parse_deploy_config(@tolerated)

    assert config["ssh"]["port"] =~ "CMS_SSH_PORT"
  end

  # Plain YAML still has to work — most of the file is not ERB at all.
  test "a config with no ERB in it is untouched" do
    assert {:ok, %{"service" => "plain"}} = Steps.parse_deploy_config("service: plain\n")
  end
end
