// Deploys LaunchpadFactory, either against local mock USDC/DEX infra for
// testing, or against Arc Testnet's real USDC with a router you supply.
//
// LOCAL (default) — deploys MockUSDC + MockFactory/MockRouter too:
//   npx hardhat node                # in one terminal
//   node deploy.mjs                 # in another
//
// ARC TESTNET — uses the real, verified USDC address, brings your own
// router (see README's "Verified Arc Testnet reference" section for why
// there's no default: no DEX has a publicly confirmed router address for
// Arc Testnet as of this writing — check docs.uniswap.org/contracts or
// whichever DEX you're integrating with for the current address before
// running this):
//   NETWORK=arc-testnet \
//   PRIVATE_KEY=0x... \
//   ROUTER_ADDRESS=0x... \
//   node deploy.mjs
//
// Optional in either mode:
//   PLATFORM_FEE_RECIPIENT=0x...   # who gets the platform's cut (default: none)
//   PLATFORM_FEE_BPS=20            # platform's slice of the 1% total fee, in bps (default: 0)
//   RPC_URL=https://...            # overrides the network's default RPC

import "dotenv/config"; // loads .env into process.env if one exists (silently no-ops otherwise)
import { ethers } from "ethers";
import fs from "fs";

const NETWORK = process.env.NETWORK || "local";

const NETWORKS = {
  local: { rpc: "http://127.0.0.1:8545", chainId: 31337n, usdc: null },
  "arc-testnet": {
    rpc: "https://rpc.testnet.arc.network",
    chainId: 5042002n,
    // Verified directly against docs.arc.io/arc/references/contract-addresses.
    // This is the ERC-20 interface (6 decimals) — see README for why that
    // matters and how it differs from the native gas-token representation
    // at the same address.
    usdc: "0x3600000000000000000000000000000000000000",
  },
};

const net = NETWORKS[NETWORK];
if (!net) {
  console.error(`Unknown NETWORK "${NETWORK}". Valid: ${Object.keys(NETWORKS).join(", ")}`);
  process.exit(1);
}

const RPC = process.env.RPC_URL || net.rpc;
const platformFeeRecipient = process.env.PLATFORM_FEE_RECIPIENT || ethers.ZeroAddress;
const platformFeeBps = BigInt(process.env.PLATFORM_FEE_BPS || "0");
// Default to a real 2% anti-whale cap rather than disabled — this is the
// direct mechanism against pump-and-dump (see MemecoinBondingCurve),
// deliberately opt-*out* rather than opt-in for a production-facing
// deploy script. Set to 0 explicitly if you want it off.
const maxWalletBps = BigInt(process.env.MAX_WALLET_BPS ?? "200");

const compiled = JSON.parse(fs.readFileSync("compile-output.json", "utf8"));
function artifact(file, name) {
  const c = compiled.contracts[file][name];
  return { abi: c.abi, bytecode: "0x" + c.evm.bytecode.object };
}

const MockUSDC = artifact("contracts/test/Mocks.sol", "MockUSDC");
const MockFactoryArt = artifact("contracts/test/Mocks.sol", "MockFactory");
const MockRouterArt = artifact("contracts/test/Mocks.sol", "MockRouter");
const LaunchpadFactoryArt = artifact("contracts/LaunchpadFactory.sol", "LaunchpadFactory");
const RegistryArt = artifact("contracts/TokenMetadataRegistry.sol", "TokenMetadataRegistry");

async function main() {
  if (platformFeeBps > 100n) {
    console.error(`PLATFORM_FEE_BPS=${platformFeeBps} exceeds the fixed 100 bps (1%) total trade fee. Max is 100.`);
    process.exit(1);
  }
  if (platformFeeBps > 0n && platformFeeRecipient === ethers.ZeroAddress) {
    console.error("PLATFORM_FEE_BPS is set but PLATFORM_FEE_RECIPIENT is not. Set both, or neither.");
    process.exit(1);
  }
  if (maxWalletBps > 10_000n) {
    console.error(`MAX_WALLET_BPS=${maxWalletBps} is over 100% (10000 bps) — nonsensical, fix it.`);
    process.exit(1);
  }

  const routerAddress = NETWORK === "local" ? null : process.env.ROUTER_ADDRESS;
  if (NETWORK !== "local" && (!routerAddress || !ethers.isAddress(routerAddress))) {
    console.error(
      "ROUTER_ADDRESS is required for arc-testnet and must be a real, " +
      "verified DEX router address implementing addLiquidity/getPair " +
      "(Uniswap-V2-style). No default exists because no DEX publishes a " +
      "confirmed router address for Arc Testnet as of this writing — " +
      "check docs.uniswap.org/contracts or whichever DEX you're " +
      "integrating with directly before setting this. Do not guess.\n" +
      "Failing here, before touching the network at all, on purpose."
    );
    process.exit(1);
  }

  // Only reachable once config is known-valid — nothing above this line
  // touches the network, so bad config fails in milliseconds instead of
  // hanging on an RPC call that was never going to work anyway.
  const provider = new ethers.JsonRpcProvider(RPC);
  const deployer = process.env.PRIVATE_KEY
    ? new ethers.Wallet(process.env.PRIVATE_KEY, provider)
    : await provider.getSigner(0);
  const deployerAddress = await deployer.getAddress();

  console.log(`Network:   ${NETWORK} (${RPC})`);
  console.log(`Deployer:  ${deployerAddress}`);
  console.log(`Platform fee: ${platformFeeBps} bps -> ${platformFeeRecipient}`);
  console.log(`Max wallet (anti-whale, pre-graduation): ${maxWalletBps} bps of total supply${maxWalletBps === 0n ? " (DISABLED)" : ""}\n`);

  let usdcAddress, dexFactoryAddress;
  let finalRouterAddress = routerAddress;

  if (NETWORK === "local") {
    console.log("Deploying MockUSDC + MockFactory + MockRouter (local testing only)...");
    const usdc = await (await new ethers.ContractFactory(MockUSDC.abi, MockUSDC.bytecode, deployer).deploy()).waitForDeployment();
    const dexFactory = await (await new ethers.ContractFactory(MockFactoryArt.abi, MockFactoryArt.bytecode, deployer).deploy()).waitForDeployment();
    const router = await (await new ethers.ContractFactory(MockRouterArt.abi, MockRouterArt.bytecode, deployer).deploy(await dexFactory.getAddress())).waitForDeployment();
    usdcAddress = await usdc.getAddress();
    finalRouterAddress = await router.getAddress();
    dexFactoryAddress = await dexFactory.getAddress();
  } else {
    usdcAddress = net.usdc;
    console.log(`Using verified Arc Testnet USDC: ${usdcAddress}`);
    console.log(`Using router (YOU verified this, not me): ${finalRouterAddress}`);
  }

  // Must match the ACTUAL USDC token's decimals, not be hardcoded — local
  // MockUSDC is 18 decimals (see contracts/test/Mocks.sol), but real USDC
  // on Arc Testnet is 6. virtualUsdcReserve and realUsdcReserve are
  // compared directly in raw units inside MemecoinBondingCurve, with no
  // decimal conversion between them, so seeding the virtual reserve in the
  // wrong decimals silently breaks the curve's pricing and makes
  // graduationThreshold effectively unreachable — no revert, just a dead
  // curve.
  const usdcDecimalsForNetwork = NETWORK === "local" ? 18 : 6;
  const initialVirtualUsdc = ethers.parseUnits(process.env.INITIAL_VIRTUAL_USDC || "3000", usdcDecimalsForNetwork);
  const graduationThreshold = ethers.parseUnits(process.env.GRADUATION_THRESHOLD || "1000", usdcDecimalsForNetwork);

  console.log("\nDeploying LaunchpadFactory...");
  const launchpad = await (
    await new ethers.ContractFactory(LaunchpadFactoryArt.abi, LaunchpadFactoryArt.bytecode, deployer).deploy(
      usdcAddress,
      finalRouterAddress,
      initialVirtualUsdc,
      graduationThreshold,
      platformFeeRecipient,
      platformFeeBps,
      maxWalletBps
    )
  ).waitForDeployment();

  console.log("Deploying TokenMetadataRegistry (independent of the factory — same one can serve multiple factories)...");
  const registry = await (await new ethers.ContractFactory(RegistryArt.abi, RegistryArt.bytecode, deployer).deploy()).waitForDeployment();

  const addresses = {
    network: NETWORK,
    rpc: RPC,
    chainId: (await provider.getNetwork()).chainId.toString(),
    deployer: deployerAddress,
    usdc: usdcAddress,
    router: finalRouterAddress,
    dexFactory: dexFactoryAddress || null,
    launchpadFactory: await launchpad.getAddress(),
    metadataRegistry: await registry.getAddress(),
    initialVirtualUsdc: initialVirtualUsdc.toString(),
    graduationThreshold: graduationThreshold.toString(),
    platformFeeRecipient,
    platformFeeBps: platformFeeBps.toString(),
    maxWalletBps: maxWalletBps.toString(),
  };

  fs.writeFileSync(`deployed-addresses.${NETWORK}.json`, JSON.stringify(addresses, null, 2));

  console.log("\nDeployed. Paste these into the frontend's config panel:\n");
  console.log(`  Factory address:  ${addresses.launchpadFactory}`);
  console.log(`  USDC address:     ${addresses.usdc}`);
  console.log(`  Registry address: ${addresses.metadataRegistry}  (optional field — enables images/socials)`);
  console.log(`  Chain ID:         ${addresses.chainId}`);
  console.log(`  RPC URL:          ${addresses.rpc}`);
  console.log(`\nFull details written to deployed-addresses.${NETWORK}.json`);

  if (NETWORK === "local" && !process.env.PRIVATE_KEY) {
    console.log(
      "\nUsing Hardhat's default local account #0. Mint yourself test USDC with:\n" +
      `  MockUSDC.attach("${addresses.usdc}").mint(yourAddress, ethers.parseUnits("10000", 18))`
    );
  }
}

main().catch((e) => {
  console.error("DEPLOY ERROR:", e);
  process.exitCode = 1;
});
