defmodule Mokaid.Repo do
  use Ecto.Repo,
    otp_app: :mokaid,
    adapter: Ecto.Adapters.Postgres
end
