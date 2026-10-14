# Run with MIX_ENV=harness mix run --no-start priv/repo/qa_963_harness.exs /path/to/runtime.json
# The runtime file is created by the development-only provisioning fixture API.
# It contains a short-lived token; never print it or commit it.

unless Mix.env() == :harness do
  Mix.raise("Run this fixture bootstrap with MIX_ENV=harness and --no-start")
end

[path] = System.argv()
runtime = path |> File.read!() |> Jason.decode!()

unless runtime["fixture"] == "story-963" do
  Mix.raise("Not a story 963 fixture runtime")
end

root = Map.fetch!(runtime, "root")
server_url = Map.fetch!(runtime, "server_url")
uri = URI.parse(server_url)

unless uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] do
  Mix.raise("The QA fixture requires a local development server")
end

System.put_env("CMS_PROJECT_DIR", root)
Application.put_env(:code_my_spec, :harness_token, Map.fetch!(runtime, "token"))
Application.put_env(:code_my_spec, :harness_server_url_override, server_url)

Application.put_env(
  :code_my_spec,
  :device_config_path,
  Path.join(Path.dirname(root), "device.json")
)

Application.put_env(
  :code_my_spec,
  :harness_served_roots_dir,
  Path.join(Path.dirname(root), "served_roots")
)

endpoint = Application.get_env(:code_my_spec, CmsHarness.Web.Endpoint, [])

Application.put_env(
  :code_my_spec,
  CmsHarness.Web.Endpoint,
  Keyword.put(endpoint, :http, ip: {127, 0, 0, 1}, port: 0)
)

# The reporter includes cwd in its inventory; never report this source checkout
# as belonging to the disposable fixture device.
File.cd!(root)

# Start the normal harness only after its isolated configuration is in place.
{:ok, _} = Application.ensure_all_started(:code_my_spec)

IO.puts(
  "Story 963 fixture harness started for #{runtime["project_id"]}. Keep this process running during QA."
)

Process.sleep(:infinity)
