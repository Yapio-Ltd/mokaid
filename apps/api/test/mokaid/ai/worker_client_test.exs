defmodule Mokaid.AI.WorkerClientTest do
  use ExUnit.Case, async: false

  alias Mokaid.AI.WorkerClient

  describe "post/3" do
    test "noop for dispatch :none" do
      assert :ok =
               WorkerClient.post("/runs", %{run_id: "x"},
                 config: [dispatch: :none, url: nil, token: "t"]
               )
    end

    test "returns error instead of raising when HTTP url is missing" do
      assert {:error, :ai_worker_url_missing} =
               WorkerClient.post("/runs", %{run_id: "x"},
                 config: [dispatch: :http, url: nil, token: "t"]
               )
    end

    test "returns error for relative urls that would crash Finch" do
      assert {:error, :ai_worker_url_missing} =
               WorkerClient.post("/runs", %{run_id: "x"},
                 config: [dispatch: :http, url: "/runs", token: "t"]
               )
    end

    test "soft mode swallows missing url errors" do
      assert :ok =
               WorkerClient.post("/agent-chat", %{},
                 config: [dispatch: :http, url: nil, token: "t"],
                 soft: true
               )
    end

    test "unknown dispatch never falls through to HTTP" do
      assert {:error, :unsupported_dispatch} =
               WorkerClient.post("/runs", %{}, config: [dispatch: :bogus, url: nil, token: "t"])
    end
  end

  describe "absolute_url?/1" do
    test "accepts http(s) urls" do
      assert WorkerClient.absolute_url?("http://localhost:8100")
      assert WorkerClient.absolute_url?("https://worker.example/v1")
    end

    test "rejects nil blank and relative" do
      refute WorkerClient.absolute_url?(nil)
      refute WorkerClient.absolute_url?("")
      refute WorkerClient.absolute_url?("   ")
      refute WorkerClient.absolute_url?("/runs")
    end
  end
end
