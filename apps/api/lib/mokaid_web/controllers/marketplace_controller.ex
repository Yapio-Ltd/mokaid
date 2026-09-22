defmodule MokaidWeb.MarketplaceController do
  use MokaidWeb, :controller

  alias Mokaid.Marketplace
  alias Mokaid.Marketplace.{ConnectAccount, Lease, Listing, Order}
  alias MokaidWeb.JSON, as: Serializer

  def listings(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view") do
      data =
        Marketplace.list_public_listings(workspace_id(conn), params)
        |> Enum.map(&listing_json/1)

      json(conn, %{data: data})
    end
  end

  def mine(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view") do
      connect = Marketplace.get_connect_account(workspace_id(conn))

      data =
        Marketplace.list_my_agents(workspace_id(conn))
        |> Enum.map(&mine_row_json/1)

      json(conn, %{
        data: data,
        meta: %{
          min_level: Marketplace.min_level(),
          fee_percent: Marketplace.fee_percent(),
          connect: connect_json(connect),
          connect_ready: Marketplace.connect_ready?(workspace_id(conn))
        }
      })
    end
  end

  def create_listing(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         {:ok, listing} <-
           Marketplace.create_listing(workspace_id(conn), current_member(conn), params) do
      listing = Mokaid.Repo.preload(listing, :agent)
      conn |> put_status(:created) |> json(%{data: listing_json(listing)})
    end
  end

  def pause_listing(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         {:ok, listing} <- Marketplace.pause_listing(workspace_id(conn), id) do
      listing = Mokaid.Repo.preload(listing, :agent)
      json(conn, %{data: listing_json(listing)})
    end
  end

  def resume_listing(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         {:ok, listing} <- Marketplace.resume_listing(workspace_id(conn), id) do
      listing = Mokaid.Repo.preload(listing, :agent)
      json(conn, %{data: listing_json(listing)})
    end
  end

  def connect_onboard(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         country when is_binary(country) <- params["country"] || params["country_code"],
         {:ok, result} <-
           Marketplace.start_connect_onboarding(
             workspace_id(conn),
             country,
             params["return_path"] || "/marketplace/return"
           ) do
      json(conn, %{
        data: %{
          url: result.url,
          sale_url: result.url,
          account: connect_json(result.account)
        }
      })
    else
      nil -> {:error, :invalid_country}
      other -> other
    end
  end

  def checkout(conn, %{"listing_id" => listing_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.create"),
         {:ok, result} <-
           Marketplace.start_checkout(
             workspace_id(conn),
             current_member(conn),
             current_user(conn),
             listing_id
           ) do
      json(conn, %{data: result})
    end
  end

  def earnings(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      data = Marketplace.earnings(workspace_id(conn))

      json(conn, %{
        data: %{
          connect: connect_json(data.connect),
          connect_ready: data.connect_ready,
          fee_percent: data.fee_percent,
          gross_cents: data.gross_cents,
          fee_cents: data.fee_cents,
          net_cents: data.net_cents,
          listings: Enum.map(data.listings, &listing_json/1),
          orders: Enum.map(data.orders, &order_json/1),
          active_leases: Enum.map(data.active_leases, &lease_json/1)
        }
      })
    end
  end

  defp mine_row_json(row) do
    %{
      agent: Serializer.agent(row.agent),
      listing: if(row.listing, do: listing_json(row.listing)),
      knowledge_item_count: row.knowledge_item_count,
      level: row.level,
      eligible: row.eligible,
      levels_remaining: row.levels_remaining,
      min_level: Marketplace.min_level()
    }
  end

  defp listing_json(%Listing{} = listing) do
    agent = listing.agent

    %{
      id: listing.id,
      workspace_id: listing.workspace_id,
      agent_id: listing.agent_id,
      mode: listing.mode,
      rent_billing: listing.rent_billing,
      fixed_days: listing.fixed_days,
      price_cents: listing.price_cents,
      currency: listing.currency,
      title: listing.title,
      description: listing.description,
      status: listing.status,
      knowledge_item_count: listing.knowledge_item_count,
      agent_level: listing.agent_level_snapshot,
      inserted_at: listing.inserted_at,
      agent:
        if(agent,
          do: %{
            id: agent.id,
            display_name: agent.display_name,
            role_title: agent.role_title,
            department: agent.department,
            level: agent.level,
            avatar_asset_id: agent.avatar_asset_id,
            avatar_config: agent.avatar_config,
            skills: agent.skills
          }
        )
    }
  end

  defp order_json(%Order{} = order) do
    %{
      id: order.id,
      listing_id: order.listing_id,
      mode: order.mode,
      rent_billing: order.rent_billing,
      fixed_days: order.fixed_days,
      amount_cents: order.amount_cents,
      application_fee_cents: order.application_fee_cents,
      currency: order.currency,
      status: order.status,
      paid_at: order.paid_at,
      source_agent_id: order.source_agent_id,
      cloned_agent_id: order.cloned_agent_id,
      buyer_workspace_id: order.buyer_workspace_id,
      seller_workspace_id: order.seller_workspace_id
    }
  end

  defp lease_json(%Lease{} = lease) do
    %{
      id: lease.id,
      order_id: lease.order_id,
      rent_billing: lease.rent_billing,
      fixed_days: lease.fixed_days,
      status: lease.status,
      starts_at: lease.starts_at,
      expires_at: lease.expires_at,
      cloned_agent_id: lease.cloned_agent_id,
      source_agent_id: lease.source_agent_id
    }
  end

  defp connect_json(nil), do: nil

  defp connect_json(%ConnectAccount{} = account) do
    %{
      id: account.id,
      stripe_account_id: account.stripe_account_id,
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
      country: account.country,
      ready: ConnectAccount.ready?(account)
    }
  end
end
