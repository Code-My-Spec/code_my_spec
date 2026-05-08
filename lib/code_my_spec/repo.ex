defmodule CodeMySpec.Repo do
  use Boundary, top_level?: true, deps: [], exports: :all

  use Ecto.Repo,
    otp_app: :code_my_spec,
    adapter: Application.compile_env(:code_my_spec, :adapter, Ecto.Adapters.Postgres)
end
