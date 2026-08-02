defmodule Testapp.MixProject do
  use Mix.Project

  # The release name comes from the environment so one project builds `app1`
  # and `app2` — the unit, the Unix user, the database and `bin/<name>` all
  # have to agree, and building twice from one source is how they stay that
  # way.
  @app String.to_atom(System.get_env("RELEASE_APP", "app1"))

  def project do
    [
      app: @app,
      version: "0.1.0",
      elixir: "~> 1.15",
      deps: deps(),
      releases: [{@app, [include_executables_for: [:unix]]}]
    ]
  end

  def application, do: [mod: {Testapp.Application, []}, extra_applications: [:logger]]

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:postgrex, "~> 0.19"}
    ]
  end
end
