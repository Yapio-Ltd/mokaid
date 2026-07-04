defmodule Mokaid.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Mokaid.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Mokaid.DataCase
      import Mokaid.Fixtures
    end
  end

  setup tags do
    Mokaid.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mokaid.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
