defmodule MokaidWeb.ConnCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Mokaid.Fixtures

      alias Mokaid.Repo

      @endpoint MokaidWeb.Endpoint
    end
  end

  setup tags do
    Mokaid.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
