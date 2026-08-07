// Hardhat is used ONLY for `npx hardhat node` — a local JSON-RPC chain to
// deploy and test against. Actual compilation goes through
// scripts/compile.mjs (raw solc -> compile-output.json), not Hardhat's
// own compiler pipeline, so this config stays intentionally minimal.
//
// CommonJS (.cjs) on purpose: package.json sets "type": "module" for the
// rest of the repo, and Hardhat's own config loader expects CommonJS.

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "cancun",
    },
  },
  networks: {
    hardhat: {
      // Recent Hardhat versions default to a Cancun-enabled EVM, which
      // MemecoinBondingCurve's ReentrancyGuardTransient (EIP-1153) needs.
      // If `npm run node` + a buy() ever reverts with something like
      // "TSTORE" / opcode-not-supported, your Hardhat version predates
      // Cancun support — upgrade Hardhat rather than the contract.
    },
  },
};
