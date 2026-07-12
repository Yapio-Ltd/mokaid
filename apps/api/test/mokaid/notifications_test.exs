defmodule Mokaid.NotificationsTest do
  use ExUnit.Case, async: true

  alias Mokaid.Notifications

  describe "humanize_error/1" do
    test "maps credit balance SDK dumps to a clear top-up message" do
      raw =
        "Error code: 400 - {'type': 'error', 'error': {'type': 'invalid_request_error', 'message': 'Your credit balance is too low to run this request. Please purchase credits.'}}"

      assert Notifications.humanize_error(raw) =~ "credit balance is too low"
      refute Notifications.humanize_error(raw) =~ "Error code"
      refute Notifications.humanize_error(raw) =~ "invalid_request_error"
    end

    test "maps rate limit errors" do
      assert Notifications.humanize_error("Error code: 429 - rate_limit_exceeded") =~
               "temporarily overloaded"
    end

    test "maps auth errors" do
      assert Notifications.humanize_error("Error code: 401 - Incorrect API key provided") =~
               "authentication"
    end

    test "maps timeouts" do
      assert Notifications.humanize_error("Request timed out after 120s") =~ "ran out of time"
    end

    test "falls back for unknown technical dumps" do
      msg =
        Notifications.humanize_error(
          "Error code: 400 - {'type': 'error', 'error': {'type': 'invalid_request_error'}}"
        )

      assert msg =~ "Something went wrong"
      refute msg =~ "Error code"
    end

    test "keeps already-friendly copy" do
      friendly = "We couldn't complete this task because your AI credit balance is too low."
      assert Notifications.humanize_error(friendly) == friendly
    end

    test "handles nil and blank" do
      assert Notifications.humanize_error(nil) =~ "Something went wrong"
      assert Notifications.humanize_error("   ") =~ "Something went wrong"
    end

    test "maps content_policy refusal prefix" do
      assert Notifications.humanize_error(
               "content_policy: I cannot help with historically harmful symbols."
             ) =~ "content policy"
    end
  end
end
