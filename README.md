# Dappnode Package _Web3Signer_

This repo includes the Web3Signer packages for: Holesky, Hoodi, Mainnet, LUKSO and Gnosis

![](avatar.png)

<!--Brief introduction about the source project (official project definition is an option): -->

A validator client contributes to the consensus of the Ethereum Blockchain by signing proposals and attestations of blocks, using a BLS private key which must be available to this client at all times.

The BLS remote signer API is designed to be consumed by validator clients, looking for a more secure avenue to store their BLS12-381 private key(s), enabling them to run in more permissive and scalable environments.

More information about the EIP can be found at [the official website](https://eips.ethereum.org/EIPS/eip-3030)

### Why _Web3signer_ ?

<!--What can you do with this package?: -->

Client diversity is a key benefit of DAppNode, with our implementation of ConsenSys's remote Web3Signer you will be able to use different clients and don't need to put all your trust in just one validator client. The remote signer can work as a load balancer, keeping your validators always validating.

### Requirements

Rquirements to run the Web3Signer package

- **Validator**: Set up your validator at https://launchpad.ethereum.org/
- **Ethereum Node**: Set up your Ethereum full node by selecting a pair of clients (execution + consensus layers) in the Stakers menu of your Dappnode
