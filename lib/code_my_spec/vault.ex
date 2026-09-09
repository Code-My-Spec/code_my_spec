defmodule CodeMySpec.Vault do
  @moduledoc false
  use Boundary, top_level?: true, deps: [], exports: :all

  use Cloak.Vault, otp_app: :code_my_spec
end
