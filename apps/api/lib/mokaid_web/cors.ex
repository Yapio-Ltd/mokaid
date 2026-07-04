defmodule MokaidWeb.Cors do
  @moduledoc "CORS origin allowlist sourced from configuration."

  def allowed_origin?(origin) do
    origin in Application.get_env(:mokaid, :cors_origins, [])
  end
end
