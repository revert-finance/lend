#!/usr/bin/env python3

import argparse
import json
import os
import sys
from collections import defaultdict
from web3 import Web3

# --- Configuration ---

# Get RPC URL from environment variable
RPC_URL = os.getenv("ETH_RPC_URL")
if not RPC_URL:
    print("Error: ETH_RPC_URL environment variable not set.", file=sys.stderr)
    sys.exit(1)

# Deployed contract addresses on Base
GAUGE_MANAGER_ADDRESS = Web3.to_checksum_address("0x66a2481b784cf26103441ca6067f997f90d3e129")
SUGAR_ADDRESS = Web3.to_checksum_address("0x9DE6Eab7a910A288dE83a04b6A43B52Fd1246f1E")
NFPM_ADDRESS = Web3.to_checksum_address("0x827922686190790b37229fd06084350E74485b72")

# Paths to ABI files
SUGAR_ABI_PATH = "out/ISugarFixed.sol/ISugarFixed.json"
GAUGE_MANAGER_ABI_PATH = "out/GaugeManager.sol/GaugeManager.json"

# Batch size for querying the Sugar contract
BATCH_SIZE = 100

def load_abi(path):
    """Loads a contract ABI from a JSON file."""
    if not os.path.exists(path):
        print(f"Error: ABI file not found at {path}", file=sys.stderr)
        print("Please ensure the project is compiled.", file=sys.stderr)
        sys.exit(1)
    with open(path, 'r') as f:
        data = json.load(f)
        return data['abi']

def main():
    """
    Main function to scan for pools and configure gauges if necessary.
    """
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Configure gauges for CL pools')
    parser.add_argument('--dry-run', action='store_true',
                        help='Run in dry-run mode: report what would be done without executing transactions')
    args = parser.parse_args()

    if args.dry_run:
        print(">>> Starting gauge configuration script in DRY-RUN mode...")
        print(">>> No transactions will be executed\n")
    else:
        print(">>> Starting gauge configuration script...")

    # --- Setup Web3 and Contracts ---
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    if not w3.is_connected():
        print(f"Error: Could not connect to RPC at {RPC_URL}", file=sys.stderr)
        sys.exit(1)
    
    chain_id = w3.eth.chain_id
    print(f"Connected to RPC. Chain ID: {chain_id}")

    # Load private key and set up account
    private_key = os.getenv("PRIVATE_KEY")
    if not private_key:
        print("Error: PRIVATE_KEY environment variable not set.", file=sys.stderr)
        sys.exit(1)
    
    try:
        account = w3.eth.account.from_key(private_key)
        print(f"Using sender address: {account.address}")
    except Exception as e:
        print(f"Error: Invalid private key provided. {e}", file=sys.stderr)
        sys.exit(1)

    # Load ABIs and create contract instances
    sugar_abi = load_abi(SUGAR_ABI_PATH)
    gauge_manager_abi = load_abi(GAUGE_MANAGER_ABI_PATH)
    
    sugar_contract = w3.eth.contract(address=SUGAR_ADDRESS, abi=sugar_abi)
    gauge_manager_contract = w3.eth.contract(address=GAUGE_MANAGER_ADDRESS, abi=gauge_manager_abi)

    # --- Scanning Logic ---
    offset = 0
    pools_to_configure = []
    cl_pools_by_nfpm = defaultdict(list)  # Track CL pools grouped by NFPM address

    print("\n==========================================")
    print("Scanning for CL pools with active gauges...")
    print("==========================================")

    nfpm_address_checksum = Web3.to_checksum_address(NFPM_ADDRESS)

    while True:
        print(f"\nFetching batch of {BATCH_SIZE} pools at offset {offset}...")
        
        try:
            batch = sugar_contract.functions.all(BATCH_SIZE, offset, 0).call()
        except Exception as e:
            print(f"\nInfo: 'sugar.all()' reverted at offset {offset}. Assuming end of pool list.", file=sys.stderr)
            break
        
        num_in_batch = len(batch)
        print(f"  Received {num_in_batch} pools.")

        if num_in_batch == 0:
            print("  Reached end of pools.")
            break

        for pool_data in batch:
            # Unpack all 32 fields from the Lp struct (ISugarFixed version on Base)
            (
                lp, symbol, decimals, liquidity,
                type_, tick, sqrt_ratio,
                token0, reserve0, staked0,
                token1, reserve1, staked1,
                gauge, gauge_liquidity, gauge_alive,
                fee, bribe, factory,
                emissions, emissions_token, emissions_cap, pool_fee, unstaked_fee,
                token0_fees, token1_fees,
                locked, emerging, created_at,
                nfpm, alm, root
            ) = pool_data

            # Strict filter for Slipstream CL pools with active gauges
            is_cl_pool = (Web3.to_checksum_address(nfpm) == nfpm_address_checksum) and (type_ > 0)

            # Track all CL pools by NFPM address for reporting
            if is_cl_pool:
                cl_pools_by_nfpm[nfpm].append({
                    'symbol': symbol,
                    'lp': lp,
                    'gauge': gauge,
                    'gauge_alive': gauge_alive
                })

            has_active_gauge = (gauge != "0x0000000000000000000000000000000000000000") and gauge_alive

            if is_cl_pool and has_active_gauge:
                print(f"\n- Found matching pool: {symbol}")
                try:
                    existing_gauge = gauge_manager_contract.functions.poolToGauge(lp).call()
                    print(f"  Checking config for {symbol} ({lp})")
                    print(f"    Expected gauge: {gauge}")
                    print(f"    Existing gauge: {existing_gauge}")

                    if Web3.to_checksum_address(existing_gauge) == Web3.to_checksum_address(gauge):
                        print("    Status: Already configured. Skipping.")
                    else:
                        is_new = existing_gauge == "0x0000000000000000000000000000000000000000"
                        if is_new:
                            print("    Status: NEW POOL - needs configuration.")
                        else:
                            print("    Status: GAUGE CHANGED - needs configuration.")
                            print(f"    Current gauge: {existing_gauge}")
                        pools_to_configure.append({'lp': lp, 'gauge': gauge, 'symbol': symbol, 'existing_gauge': existing_gauge, 'is_new': is_new})
                except Exception as e:
                    print(f"    Could not check gauge status for {symbol}: {e}")

        if num_in_batch < BATCH_SIZE:
            print("\n  Processed the final batch.")
            break
        else:
            offset += BATCH_SIZE
    
    # --- Print CL Pools Summary by NFPM ---
    print("\n==========================================")
    print("CL POOLS SUMMARY BY NFPM ADDRESS")
    print("==========================================")
    for nfpm_addr, pools in sorted(cl_pools_by_nfpm.items()):
        print(f"\nNFPM: {nfpm_addr}")
        print(f"  Total CL pools: {len(pools)}")
        active_gauges = sum(1 for p in pools if p['gauge_alive'] and p['gauge'] != "0x0000000000000000000000000000000000000000")
        print(f"  Pools with active gauges: {active_gauges}")
        print(f"  Pools without active gauges: {len(pools) - active_gauges}")

    print(f"\nTotal CL pools across all NFPMs: {sum(len(pools) for pools in cl_pools_by_nfpm.values())}")

    # --- Transaction Sending Logic ---
    if not pools_to_configure:
        print("\n==========================================")
        print("All found CL pools are already configured correctly. Nothing to do.")
        print("==========================================")
        return

    print(f"\n==========================================")
    print(f"Found {len(pools_to_configure)} pools that need configuration.")
    print("==========================================")

    # If dry-run mode, just print summary and exit
    if args.dry_run:
        print("\n==========================================")
        print("DRY-RUN SUMMARY")
        print("==========================================")
        new_pools = [p for p in pools_to_configure if p['is_new']]
        changed_pools = [p for p in pools_to_configure if not p['is_new']]

        if new_pools:
            print(f"\nNEW POOLS ({len(new_pools)}):")
            for pool in new_pools:
                print(f"  - {pool['symbol']}")
                print(f"    Pool: {pool['lp']}")
                print(f"    Gauge: {pool['gauge']}")

        if changed_pools:
            print(f"\nGAUGE CHANGED ({len(changed_pools)}):")
            for pool in changed_pools:
                print(f"  - {pool['symbol']}")
                print(f"    Pool: {pool['lp']}")
                print(f"    Current gauge: {pool['existing_gauge']}")
                print(f"    New gauge:     {pool['gauge']}")

        print("\n** No transactions executed in dry-run mode **")
        return

    configured_count = 0
    failed_count = 0

    # Process in batches of 10
    batch_size = 10
    for i in range(0, len(pools_to_configure), batch_size):
        batch = pools_to_configure[i:i + batch_size]

        print(f"\n--- Preparing to configure batch {i//batch_size + 1} of {(len(pools_to_configure) + batch_size - 1)//batch_size} ---")
        for pool in batch:
            print(f"  - {pool['symbol']}")

        try:
            proceed = input("Press Enter to configure this batch or type 'n' to cancel: ")
            if proceed.lower() == 'n':
                print("Skipping remaining batches.")
                break # Exit the main batch loop
        except KeyboardInterrupt:
            print("\nCancelled by user.")
            break

        # Get initial nonce for the batch (including pending transactions)
        nonce = w3.eth.get_transaction_count(account.address, 'pending')
        print(f"Starting batch with nonce: {nonce}")

        # Send transactions for the current batch
        for pool in batch:
            tx_sent = False
            try:
                print(f"\nConfiguring {pool['symbol']} ({pool['lp']})...")
                print(f"  Using nonce: {nonce}")

                tx_data = gauge_manager_contract.functions.setGauge(
                    pool['lp'],
                    pool['gauge']
                ).build_transaction({
                    'from': account.address,
                    'nonce': nonce,
                    'gas': 200000,
                    'gasPrice': w3.eth.gas_price,
                    'chainId': chain_id
                })

                signed_tx = w3.eth.account.sign_transaction(tx_data, private_key=private_key)
                tx_hash = w3.eth.send_raw_transaction(signed_tx.rawTransaction)
                tx_sent = True  # Mark that transaction was broadcast
                print(f"  Transaction sent: {tx_hash.hex()}")

                print("  Waiting for receipt...")
                receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)

                if receipt.status == 1:
                    print(f"  Transaction successful for {pool['symbol']}!")
                    configured_count += 1
                else:
                    print(f"  Transaction FAILED for {pool['symbol']}! Receipt: {receipt}")
                    failed_count += 1

            except Exception as e:
                print(f"  Failed to send transaction for {pool['symbol']}: {e}")
                failed_count += 1
            finally:
                # Only increment nonce if transaction was actually broadcast to the network
                if tx_sent:
                    nonce += 1

    print("\n==========================================")
    print("CONFIGURATION SCRIPT COMPLETE")
    print("==========================================")
    print(f"Successfully configured: {configured_count}")
    print(f"Failed to configure: {failed_count}")
    print(f"Total pools that needed configuration: {len(pools_to_configure)}")

if __name__ == "__main__":
    main()
