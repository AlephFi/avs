#!/usr/bin/env python3
"""
Prepares airdrop CSV with amounts scaled to the token's decimals.

Reads token decimals automatically from the blockchain.

Usage:
    python scripts/prepare_airdrop_csv.py <input_csv> <token_address> [output_csv]

Example:
    python scripts/prepare_airdrop_csv.py eigen_yields_airdrop.csv 0x639E387DE0fF0E68a42b5Ae77b86dA8F0e15623c

Environment:
    RPC_URL - Required. The RPC endpoint to query token decimals.
"""

import os
import sys
import csv
import json
import urllib.request
from decimal import Decimal, ROUND_DOWN


def get_token_decimals(rpc_url: str, token_address: str) -> int:
    """Query token decimals from the blockchain."""
    # decimals() function selector
    data = {
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{
            "to": token_address,
            "data": "0x313ce567"  # decimals()
        }, "latest"],
        "id": 1
    }

    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(data).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )

    with urllib.request.urlopen(req, timeout=10) as response:
        result = json.loads(response.read().decode('utf-8'))
        if 'error' in result:
            raise Exception(f"RPC error: {result['error']}")
        # Parse hex result
        return int(result['result'], 16)


def get_token_symbol(rpc_url: str, token_address: str) -> str:
    """Query token symbol from the blockchain."""
    data = {
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{
            "to": token_address,
            "data": "0x95d89b41"  # symbol()
        }, "latest"],
        "id": 1
    }

    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(data).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            result = json.loads(response.read().decode('utf-8'))
            if 'error' in result or not result.get('result'):
                return "UNKNOWN"
            # Decode string from ABI-encoded result
            hex_data = result['result'][2:]  # Remove 0x
            if len(hex_data) < 128:
                return "UNKNOWN"
            # Skip offset (32 bytes) and length (32 bytes), then decode string
            length = int(hex_data[64:128], 16)
            symbol_hex = hex_data[128:128 + length * 2]
            return bytes.fromhex(symbol_hex).decode('utf-8').strip('\x00')
    except:
        return "UNKNOWN"


def prepare_csv(input_path: str, decimals: int, output_path: str = None, min_amount: Decimal = None):
    """
    Prepare CSV with scaled integer amounts.

    Args:
        input_path: Input CSV with address,amount format
        decimals: Token decimals
        output_path: Output CSV path (default: airdrop_prepared.csv)
        min_amount: Minimum token amount to include (default: 1 smallest unit)
    """
    if output_path is None:
        output_path = "airdrop_prepared.csv"

    # Default minimum is 0.00001 tokens
    if min_amount is None:
        min_amount = Decimal('0.00001')

    min_scaled = int(min_amount * Decimal(10 ** decimals))

    total = Decimal('0')
    total_original = Decimal('0')
    count = 0
    dust_count = 0
    dust_total = Decimal('0')

    with open(input_path, 'r') as f_in, open(output_path, 'w') as f_out:
        reader = csv.reader(f_in)
        for row in reader:
            if len(row) < 2:
                continue

            addr = row[0].strip()
            try:
                amount = Decimal(row[1].strip())
            except:
                continue

            total_original += amount

            # Scale to integer with target decimals
            scaled = amount * Decimal(10 ** decimals)
            amount_int = int(scaled.to_integral_value(rounding=ROUND_DOWN))

            if amount_int >= min_scaled:
                f_out.write(f'{addr},{amount_int}\n')
                total += Decimal(amount_int)
                count += 1
            else:
                dust_count += 1
                dust_total += amount

    print(f'Input:      {input_path}')
    print(f'Output:     {output_path}')
    print(f'Decimals:   {decimals}')
    print(f'Min amount: {min_amount} tokens')
    print(f'---')
    print(f'Recipients:   {count}')
    print(f'Dust removed: {dust_count} addresses ({dust_total:.10f} tokens)')
    print(f'---')
    print(f'Original total: {total_original:.6f} tokens')
    print(f'Final total:    {total / Decimal(10 ** decimals):.6f} tokens')
    print(f'Dust loss:      {dust_total:.10f} tokens')

    return output_path


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(__doc__)
        print("\nOptional: --min-amount <tokens> to set minimum threshold")
        print("Example: python scripts/prepare_airdrop_csv.py input.csv 0x... --min-amount 0.01")
        sys.exit(1)

    input_csv = sys.argv[1]
    token_address = sys.argv[2]
    output_csv = None
    min_amount = None

    # Parse optional arguments
    i = 3
    while i < len(sys.argv):
        if sys.argv[i] == '--min-amount' and i + 1 < len(sys.argv):
            min_amount = Decimal(sys.argv[i + 1])
            i += 2
        else:
            output_csv = sys.argv[i]
            i += 1

    # Get RPC URL from environment
    rpc_url = os.environ.get('RPC_URL')
    if not rpc_url:
        print("Error: RPC_URL environment variable is required")
        sys.exit(1)

    # Fetch token info
    print(f"Fetching token info from {token_address}...")
    try:
        decimals = get_token_decimals(rpc_url, token_address)
        symbol = get_token_symbol(rpc_url, token_address)
        print(f"Token: {symbol}")
        print(f"Decimals: {decimals}")
        print()
    except Exception as e:
        print(f"Error fetching token info: {e}")
        sys.exit(1)

    prepare_csv(input_csv, decimals, output_csv, min_amount)
