defmodule MokaidWeb.Presence do
  @moduledoc """
  Phoenix Presence for online users, members and human-linked agents.
  """
  use Phoenix.Presence,
    otp_app: :mokaid,
    pubsub_server: Mokaid.PubSub
end
