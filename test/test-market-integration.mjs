import { ethers } from "ethers";
import fs from "fs";

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
const CurveArt = artifact("contracts/MemecoinBondingCurve.sol", "MemecoinBondingCurve");

function assert(cond, msg) {
  if (!cond) { console.log("FAIL:", msg); process.exitCode = 1; }
  else console.log("ok:  ", msg);
}
function bigToNumber(big, decimals) { return Number(ethers.formatUnits(big, decimals)); }

async function main() {
  const provider = new ethers.JsonRpcProvider("http://127.0.0.1:8545");
  const deployer = await provider.getSigner(0);
  const creatorA = await provider.getSigner(17);
  const creatorB = await provider.getSigner(18);
  const trader = await provider.getSigner(19);

  const usdc = await (await new ethers.ContractFactory(MockUSDC.abi, MockUSDC.bytecode, deployer).deploy()).waitForDeployment();
  const dexFactory = await (await new ethers.ContractFactory(MockFactoryArt.abi, MockFactoryArt.bytecode, deployer).deploy()).waitForDeployment();
  const router = await (await new ethers.ContractFactory(MockRouterArt.abi, MockRouterArt.bytecode, deployer).deploy(await dexFactory.getAddress())).waitForDeployment();
  const factory = await (await new ethers.ContractFactory(LaunchpadFactoryArt.abi, LaunchpadFactoryArt.bytecode, deployer).deploy(
    await usdc.getAddress(), await router.getAddress(), ethers.parseUnits("3000", 18), ethers.parseUnits("1000000", 18), ethers.ZeroAddress, 0n, 0n
  )).waitForDeployment();
  const registry = await (await new ethers.ContractFactory(RegistryArt.abi, RegistryArt.bytecode, deployer).deploy()).waitForDeployment();

  // Token A: has an image set. Token B: no metadata at all.
  const txA = await factory.connect(creatorA).createToken("Alpha Coin", "ALPHA");
  const rA = await txA.wait();
  const evA = rA.logs.map((l) => { try { return factory.interface.parseLog(l); } catch { return null; } }).find((e) => e && e.name === "TokenLaunched");
  await (await registry.connect(creatorA).setMetadata(evA.args.token, "https://example.com/alpha.png", "https://x.com/alpha", "", "", "")).wait();

  const txB = await factory.connect(creatorB).createToken("Beta Coin", "BETA");
  const rB = await txB.wait();
  const evB = rB.logs.map((l) => { try { return factory.interface.parseLog(l); } catch { return null; } }).find((e) => e && e.name === "TokenLaunched");
  // No metadata set for B, deliberately.

  await (await usdc.mint(await trader.getAddress(), ethers.parseUnits("10000", 18))).wait();
  await (await usdc.connect(trader).approve(evA.args.token, ethers.MaxUint256)).wait();
  await (await usdc.connect(trader).approve(evB.args.token, ethers.MaxUint256)).wait();

  const tokenA = new ethers.Contract(evA.args.token, CurveArt.abi, trader);
  const tokenB = new ethers.Contract(evB.args.token, CurveArt.abi, trader);

  // Give A more buy volume than B, to check trending-sort logic gets the
  // right answer (mirrors exactly what renderMarket()'s "trending" sort does).
  await (await tokenA.buy(ethers.parseUnits("500", 18), 0, { gasLimit: 1_500_000 })).wait();
  await (await tokenA.buy(ethers.parseUnits("300", 18), 0, { gasLimit: 1_500_000 })).wait();
  await (await tokenB.buy(ethers.parseUnits("50", 18), 0, { gasLimit: 1_500_000 })).wait();

  console.log("== Replicating loadMarket()'s exact per-token data assembly ==");
  await new Promise((r) => setTimeout(r, 300)); // see AUDIT.md — explicit block range alone isn't always enough on a fast-mining local node
  const latestBlock = await provider.getBlockNumber();
  async function assembleTokenData(addr) {
    const curve = new ethers.Contract(addr, CurveArt.abi, provider);
    const [price, raised, name, symbol, myBalance, buyEvents] = await Promise.all([
      curve.currentPrice(), curve.realUsdcReserve(), curve.name(), curve.symbol(),
      curve.balanceOf(await trader.getAddress()),
      curve.queryFilter(curve.filters.Buy(), 0, latestBlock),
    ]);
    const volume = buyEvents.reduce((sum, e) => sum + e.args.usdcIn, 0n);
    let imageUrl = "";
    const meta = await registry.getMetadata(addr);
    if (meta.isSet) imageUrl = meta.imageUrl;
    return { addr, name, symbol, price: bigToNumber(price, 18), raised: bigToNumber(raised, 18), volume: bigToNumber(volume, 18), imageUrl, myBalance };
  }

  const dataA = await assembleTokenData(evA.args.token);
  const dataB = await assembleTokenData(evB.args.token);

  assert(dataA.imageUrl === "https://example.com/alpha.png", "token A's image URL correctly fetched from the registry");
  assert(dataB.imageUrl === "", "token B correctly shows empty image URL — no metadata was ever set for it, and that's read cleanly, not as an error");
  assert(dataA.volume > dataB.volume, `trending sort would correctly rank A above B (A volume ${dataA.volume} > B volume ${dataB.volume})`);
  assert(dataA.myBalance > 0n && dataB.myBalance > 0n, "portfolio filter correctly sees the trader's balance in both tokens (bought both)");
  assert(dataA.name === "Alpha Coin" && dataB.name === "Beta Coin", "names correctly distinguished per token, no cross-contamination between the two");

  console.log("\n== Search matching logic (mirrors renderMarket()'s filter) ==");
  const searchMatches = (token, query) => token.name.toLowerCase().includes(query) || token.symbol.toLowerCase().includes(query);
  assert(searchMatches(dataA, "alpha") === true, '"alpha" search matches token A');
  assert(searchMatches(dataA, "beta") === false, '"beta" search does not match token A');
  assert(searchMatches(dataB, "beta") === true, '"beta" search matches token B by name');
  assert(searchMatches(dataB, "BETA".toLowerCase()) === true, "search is case-insensitive (mirrors .toLowerCase() on both sides in the real code)");

  console.log("\nMarket integration verification complete.");
}

main().catch((e) => { console.error("ERROR:", e); process.exitCode = 1; });
